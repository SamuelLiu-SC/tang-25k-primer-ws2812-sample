library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity led is
    Port (
        ws2812 : out STD_LOGIC;
        -- Player 1 paddle (LED 0):  R=H5, G=H8, B=G7 -> pin_in(0..2)
        -- Player 2 paddle (LED 49): R=J5, B=G8, G=H7 -> pin_in(3..5)
        pin_in : in  STD_LOGIC_VECTOR(5 downto 0);
        -- SSD1306 128x64 OLED, open-drain I2C bus (assumes 0x3C 7-bit address)
        oled_scl : inout STD_LOGIC;
        oled_sda : inout STD_LOGIC
    );
end led;

architecture Behavioral of led is
    component OSCA
        generic (FREQ_DIV : integer := 16);
        port (
            OSCOUT : out STD_LOGIC;
            OSCEN  : in  STD_LOGIC
        );
    end component;

    -- Internal 210MHz chip oscillator / 16 = ~13.125MHz; doesn't depend on any external crystal
    signal clk : STD_LOGIC;

    -- WS2812 timing @ ~13.125 MHz clk (76.19ns/cycle)
    constant T0H_CYCLES    : integer := 5;   -- 0.38us
    constant T1H_CYCLES    : integer := 10;  -- 0.76us
    constant BIT_CYCLES    : integer := 16;  -- 1.22us total bit period
    constant RESET_CYCLES  : integer := 4000; -- >300us latch/reset gap (WS2812B-V5 needs >=280us)

    constant NUM_LEDS      : integer := 50; -- LEDs chained on the ws2812 line; court runs LED 0 (P1) .. LED 49 (P2)

    type ws2812_state_t is (ST_RESET, ST_BIT_HIGH, ST_BIT_LOW);
    signal ws_state    : ws2812_state_t := ST_RESET;
    signal ws_timer    : integer range 0 to RESET_CYCLES - 1 := 0;
    signal ws_bit_idx  : integer range 0 to 23 := 23;
    signal ws_led_idx  : integer range 0 to NUM_LEDS - 1 := 0;
    signal ws_color    : std_logic_vector(23 downto 0) := (others => '0');
    signal ws_high_len : integer range 0 to T1H_CYCLES := 0;

    -- Double-flop synchronizers for the async pin_in inputs
    signal pin_in_meta : std_logic_vector(5 downto 0) := (others => '0');
    signal pin_in_sync : std_logic_vector(5 downto 0) := (others => '0');

    -- Debounce: only accept a pin change once it has held steady for a full DEBOUNCE_TICKS period
    constant DEBOUNCE_TICKS : integer := 13124; -- ~1ms at ~13.125MHz
    signal db_counter : integer range 0 to DEBOUNCE_TICKS - 1 := 0;
    signal pin_prev    : std_logic_vector(5 downto 0) := (others => '0');
    signal pin_stable  : std_logic_vector(5 downto 0) := (others => '0');

    -- Button bit positions within pin_in / pin_stable
    constant P1_R : integer := 0;
    constant P1_G : integer := 1;
    constant P1_B : integer := 2;
    constant P2_R : integer := 3;
    constant P2_B : integer := 4;
    constant P2_G : integer := 5;

    -- Palette, GRB byte order (as consumed by the WS2812 shift-out below)
    constant COLOR_WHITE      : std_logic_vector(23 downto 0) := x"FFFFFF";
    constant COLOR_RED        : std_logic_vector(23 downto 0) := x"00FF00";
    constant COLOR_GREEN      : std_logic_vector(23 downto 0) := x"FF0000";
    constant COLOR_BLUE       : std_logic_vector(23 downto 0) := x"0000FF";
    constant P1_ZONE_COLOR    : std_logic_vector(23 downto 0) := x"00000F"; -- dim blue backdrop
    constant P2_ZONE_COLOR    : std_logic_vector(23 downto 0) := x"000F00"; -- dim red backdrop
    constant MISS_FLASH_COLOR : std_logic_vector(23 downto 0) := COLOR_RED;

    -- Game timing: one game tick =~ 10ms, independent of the fast WS2812 shift-out clock
    constant GAME_TICK_CYCLES : integer := 131250; -- ~10ms at ~13.125MHz
    signal game_tick_counter  : integer range 0 to GAME_TICK_CYCLES - 1 := 0;
    signal game_tick          : std_logic := '0';

    -- Ball speed, in game ticks per court-position move; speeds up after every hit
    constant INITIAL_MOVE_PERIOD : integer := 15; -- ~150ms/step at the start of a rally
    constant MIN_MOVE_PERIOD     : integer := 5;  -- ~50ms/step, fastest allowed (was 3 - too fast to react to)
    signal move_period       : integer range MIN_MOVE_PERIOD to INITIAL_MOVE_PERIOD := INITIAL_MOVE_PERIOD;
    signal move_tick_counter : integer range 0 to INITIAL_MOVE_PERIOD - 1 := 0;

    -- Miss flash: blink the losing side a few times before serving again
    constant FLASH_HALF_PERIOD : integer := 15; -- ~150ms per on/off half-cycle
    constant FLASH_HALVES      : integer := 6;  -- 3 full flashes
    signal flash_timer       : integer range 0 to FLASH_HALF_PERIOD - 1 := 0;
    signal flash_halves_done : integer range 0 to FLASH_HALVES - 1 := 0;
    signal flash_on          : std_logic := '0';

    -- Catch zone: the last few LEDs before each paddle all count as within reach,
    -- instead of only the very last LED, giving several ticks to react
    constant PADDLE_ZONE : integer := 4;

    type game_state_t is (ST_WAIT_SERVE, ST_PLAY, ST_MISS_FLASH, ST_ROUND_READY, ST_GAME_OVER);
    signal game_state       : game_state_t := ST_WAIT_SERVE;
    signal ball_pos         : integer range 0 to NUM_LEDS - 1 := NUM_LEDS / 2;
    signal ball_going_right : std_logic := '1';
    signal ball_color       : std_logic_vector(23 downto 0) := COLOR_WHITE;
    signal miss_side        : std_logic := '0'; -- '0' = Player 1's end missed, '1' = Player 2's end missed
    signal server_is_p1     : std_logic := '1'; -- '1' = P1 sets the color and P2 must match it, '0' = vice versa

    -- Player scores, shown on the OLED
    constant WIN_SCORE    : integer := 7; -- first to reach this many points freezes the game
    signal score_p1      : integer range 0 to 99 := 0;
    signal score_p2      : integer range 0 to 99 := 0;
    signal score_toggle   : std_logic := '0'; -- flipped by the game logic whenever a score changes

    -- Color for a given LED index; called with an explicit index so the WS2812 driver
    -- never samples the game state through the (one-cycle-late) ws_led_idx register
    impure function court_color(idx : integer) return std_logic_vector is
    begin
        if game_state = ST_MISS_FLASH and flash_on = '1' then
            if (miss_side = '0' and idx < NUM_LEDS / 2) or (miss_side = '1' and idx >= NUM_LEDS / 2) then
                return MISS_FLASH_COLOR;
            end if;
        end if;

        if game_state = ST_PLAY and idx = ball_pos then
            return ball_color;
        end if;

        if idx < NUM_LEDS / 2 then
            return P1_ZONE_COLOR;
        else
            return P2_ZONE_COLOR;
        end if;
    end function;

    function hit_color(r, g, b : std_logic) return std_logic_vector is
    begin
        if r = '1' then
            return COLOR_RED;
        elsif g = '1' then
            return COLOR_GREEN;
        else
            return COLOR_BLUE;
        end if;
    end function;

    -- True if the receiver pressed the button matching the ball's current color
    function color_matches(ball_col : std_logic_vector(23 downto 0); r, g, b : std_logic) return std_logic is
    begin
        if ball_col = COLOR_RED and r = '1' then
            return '1';
        elsif ball_col = COLOR_GREEN and g = '1' then
            return '1';
        elsif ball_col = COLOR_BLUE and b = '1' then
            return '1';
        else
            return '0';
        end if;
    end function;

    -- SSD1306 OLED, driven by a bit-banged open-drain I2C master
    constant OLED_ADDR_BYTE : std_logic_vector(7 downto 0) := x"78"; -- 0x3C write

    type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);
    constant INIT_SEQ : byte_array_t := (
        OLED_ADDR_BYTE, x"00",
        x"AE", x"D5", x"80", x"A8", x"3F", x"D3", x"00", x"40",
        x"8D", x"14", x"20", x"00", x"A1", x"C8", x"DA", x"12",
        x"81", x"7F", x"D9", x"F1", x"DB", x"40", x"A4", x"A6",
        x"21", x"00", x"7F", x"22", x"00", x"07", x"AF"
    );
    constant DATA_SEQ_LEN : integer := 1026; -- address + control byte (0x40) + all 8 pages x 128 column bytes

    -- 5x7 font for digits 0-9, one byte per glyph column (bit0 = top pixel of the page)
    type font_row_t is array (0 to 4) of std_logic_vector(7 downto 0);
    type font_table_t is array (0 to 9) of font_row_t;
    constant DIGIT_FONT : font_table_t := (
        0 => (x"3E", x"41", x"41", x"41", x"3E"),
        1 => (x"00", x"42", x"7F", x"40", x"00"),
        2 => (x"42", x"61", x"51", x"49", x"46"),
        3 => (x"22", x"41", x"49", x"49", x"36"),
        4 => (x"18", x"14", x"12", x"7F", x"10"),
        5 => (x"27", x"45", x"45", x"45", x"39"),
        6 => (x"3C", x"4A", x"49", x"49", x"30"),
        7 => (x"01", x"71", x"09", x"05", x"03"),
        8 => (x"36", x"49", x"49", x"49", x"36"),
        9 => (x"06", x"49", x"49", x"29", x"1E")
    );
    constant LETTER_V : font_row_t := (x"0F", x"30", x"40", x"30", x"0F");
    -- (letter 'S' reuses the DIGIT_FONT(5) glyph, since a block '5' already reads as an 'S')

    constant GLYPH_W : integer := 5; -- font columns

    -- Each score is a single big digit (0-9); "VS" sits smaller in the middle
    constant SCALE_SCORE : integer := 8;
    constant DIGIT_W     : integer := GLYPH_W * SCALE_SCORE; -- 40px
    constant DIGIT_H     : integer := 7 * SCALE_SCORE;       -- 56px
    constant DIGIT_Y     : integer := (64 - DIGIT_H) / 2;    -- vertically centered
    constant P1_DIGIT_X  : integer := 4;
    constant P2_DIGIT_X  : integer := 128 - 4 - DIGIT_W;

    constant SCALE_VS  : integer := 3;
    constant LETTER_W  : integer := GLYPH_W * SCALE_VS; -- 15px
    constant LETTER_H  : integer := 7 * SCALE_VS;       -- 21px
    constant VS_GAP    : integer := 3;
    constant VS_Y      : integer := (64 - LETTER_H) / 2;
    constant VS_V_X    : integer := (128 - (LETTER_W * 2 + VS_GAP)) / 2;
    constant VS_S_X    : integer := VS_V_X + LETTER_W + VS_GAP;

    -- Whether pixel (x,y) of the 128x64 screen is lit: P1's digit, P2's digit, or "VS"
    -- (p2 is drawn on the left, p1 on the right, per the earlier requested swap)
    function score_pixel(x, y, p1, p2 : integer) return std_logic is
        variable col, row : integer;
    begin
        if x >= P1_DIGIT_X and x < P1_DIGIT_X + DIGIT_W and y >= DIGIT_Y and y < DIGIT_Y + DIGIT_H then
            col := (x - P1_DIGIT_X) / SCALE_SCORE;
            row := (y - DIGIT_Y) / SCALE_SCORE;
            return DIGIT_FONT(p2 mod 10)(col)(row);
        elsif x >= P2_DIGIT_X and x < P2_DIGIT_X + DIGIT_W and y >= DIGIT_Y and y < DIGIT_Y + DIGIT_H then
            col := (x - P2_DIGIT_X) / SCALE_SCORE;
            row := (y - DIGIT_Y) / SCALE_SCORE;
            return DIGIT_FONT(p1 mod 10)(col)(row);
        elsif x >= VS_V_X and x < VS_V_X + LETTER_W and y >= VS_Y and y < VS_Y + LETTER_H then
            col := (x - VS_V_X) / SCALE_VS;
            row := (y - VS_Y) / SCALE_VS;
            return LETTER_V(col)(row);
        elsif x >= VS_S_X and x < VS_S_X + LETTER_W and y >= VS_Y and y < VS_Y + LETTER_H then
            col := (x - VS_S_X) / SCALE_VS;
            row := (y - VS_Y) / SCALE_VS;
            return DIGIT_FONT(5)(col)(row);
        else
            return '0';
        end if;
    end function;

    -- Data byte (idx 0..1023: page 0's 128 columns, then page 1's, ... through page 7's)
    function score_row_byte(idx, p1, p2 : integer) return std_logic_vector is
        variable page, x : integer;
        variable b : std_logic_vector(7 downto 0);
    begin
        page := idx / 128;
        x    := idx mod 128;
        for i in 0 to 7 loop
            b(i) := score_pixel(x, page * 8 + i, p1, p2);
        end loop;
        return b;
    end function;

    type i2c_txn_t is (TXN_INIT, TXN_DATA);

    function seq_len(txn : i2c_txn_t) return integer is
    begin
        if txn = TXN_INIT then
            return INIT_SEQ'length;
        else
            return DATA_SEQ_LEN;
        end if;
    end function;

    function seq_byte(txn : i2c_txn_t; idx, p1, p2 : integer) return std_logic_vector is
    begin
        if txn = TXN_INIT then
            return INIT_SEQ(idx);
        elsif idx = 0 then
            return OLED_ADDR_BYTE;
        elsif idx = 1 then
            return x"40";
        else
            return score_row_byte(idx - 2, p1, p2);
        end if;
    end function;

    constant BOOT_DELAY_CYCLES : integer := 1312500; -- ~100ms power-up wait before talking to the OLED
    constant I2C_HALF_PERIOD   : integer := 66;      -- ~5.03us => ~100kHz I2C standard mode

    type i2c_state_t is (ST_BOOT_DELAY, ST_I2C_START, ST_I2C_BIT_LOW, ST_I2C_BIT_HIGH,
                          ST_I2C_STOP1, ST_I2C_STOP2, ST_I2C_STOP3, ST_I2C_IDLE);
    signal i2c_state    : i2c_state_t := ST_BOOT_DELAY;
    signal boot_timer   : integer range 0 to BOOT_DELAY_CYCLES - 1 := 0;
    signal i2c_timer    : integer range 0 to I2C_HALF_PERIOD - 1 := 0;
    signal i2c_txn      : i2c_txn_t := TXN_INIT;
    signal i2c_byte_idx : integer range 0 to DATA_SEQ_LEN - 1 := 0;
    signal i2c_bit_idx  : integer range 0 to 8 := 0;
    signal i2c_cur_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal scl_low      : std_logic := '0'; -- '1' = actively drive SCL low; '0' = release (pulled up high)
    signal sda_low      : std_logic := '0'; -- '1' = actively drive SDA low; '0' = release (pulled up high)
    signal score_toggle_seen : std_logic := '0'; -- last score_toggle value the OLED has drawn
begin

    oled_scl <= '0' when scl_low = '1' else 'Z';
    oled_sda <= '0' when sda_low = '1' else 'Z';

    u_osca : OSCA
        generic map (FREQ_DIV => 16)
        port map (
            OSCOUT => clk,
            OSCEN  => '1'
        );

    -- Synchronize async pin_in inputs into the clk domain
    process(clk)
    begin
        if rising_edge(clk) then
            pin_in_meta <= pin_in;
            pin_in_sync <= pin_in_meta;
        end if;
    end process;

    -- Debounce: latch a bit into pin_stable only when it matches the prior tick's sample
    process(clk)
    begin
        if rising_edge(clk) then
            if db_counter = DEBOUNCE_TICKS - 1 then
                db_counter <= 0;
                for i in 0 to 5 loop
                    if pin_in_sync(i) = pin_prev(i) then
                        pin_stable(i) <= pin_in_sync(i);
                    end if;
                end loop;
                pin_prev <= pin_in_sync;
            else
                db_counter <= db_counter + 1;
            end if;
        end if;
    end process;

    -- ~10ms game tick, independent of the fast WS2812 shift-out clock
    process(clk)
    begin
        if rising_edge(clk) then
            if game_tick_counter = GAME_TICK_CYCLES - 1 then
                game_tick_counter <= 0;
                game_tick <= '1';
            else
                game_tick_counter <= game_tick_counter + 1;
                game_tick <= '0';
            end if;
        end if;
    end process;

    -- Game logic: ball motion, paddle hit/miss detection, speed-up and miss flash
    process(clk)
        variable p1_hit : std_logic;
        variable p2_hit : std_logic;
    begin
        if rising_edge(clk) then
            if game_tick = '1' then
                -- Buttons are wired to ground with an internal pull-up, so a press reads '0'
                p1_hit := (not pin_stable(P1_R)) or (not pin_stable(P1_G)) or (not pin_stable(P1_B));
                p2_hit := (not pin_stable(P2_R)) or (not pin_stable(P2_G)) or (not pin_stable(P2_B));

                case game_state is
                    when ST_WAIT_SERVE =>
                        -- Whoever presses first becomes server: sets color on every hit,
                        -- while the other player must match that color to return it
                        if p1_hit = '1' then
                            server_is_p1 <= '1';
                            ball_pos <= 0;
                            ball_going_right <= '1';
                            ball_color <= hit_color(not pin_stable(P1_R), not pin_stable(P1_G), not pin_stable(P1_B));
                            game_state <= ST_PLAY;
                        elsif p2_hit = '1' then
                            server_is_p1 <= '0';
                            ball_pos <= NUM_LEDS - 1;
                            ball_going_right <= '0';
                            ball_color <= hit_color(not pin_stable(P2_R), not pin_stable(P2_G), not pin_stable(P2_B));
                            game_state <= ST_PLAY;
                        end if;

                    when ST_PLAY =>
                        if move_tick_counter = move_period - 1 then
                            move_tick_counter <= 0;

                            if ball_pos < PADDLE_ZONE and ball_going_right = '0' then
                                -- Player 1's catch zone: server may hit with any button and pick
                                -- a new color; the receiver must match the ball's current color
                                if (server_is_p1 = '1' and p1_hit = '1') or
                                   (server_is_p1 = '0' and color_matches(ball_color, not pin_stable(P1_R), not pin_stable(P1_G), not pin_stable(P1_B)) = '1') then
                                    ball_going_right <= '1';
                                    if server_is_p1 = '1' then
                                        ball_color <= hit_color(not pin_stable(P1_R), not pin_stable(P1_G), not pin_stable(P1_B));
                                    end if;
                                    if move_period > MIN_MOVE_PERIOD then
                                        move_period <= move_period - 1;
                                    end if;
                                elsif ball_pos = 0 then
                                    miss_side <= '0';
                                    game_state <= ST_MISS_FLASH;
                                    flash_timer <= 0;
                                    flash_halves_done <= 0;
                                    flash_on <= '1';
                                    if score_p2 < 99 then
                                        score_p2 <= score_p2 + 1;
                                    end if;
                                    score_toggle <= not score_toggle;
                                else
                                    ball_pos <= ball_pos - 1; -- still time to react
                                end if;
                            elsif ball_pos >= NUM_LEDS - PADDLE_ZONE and ball_going_right = '1' then
                                -- Player 2's catch zone: same server/receiver rule, mirrored
                                if (server_is_p1 = '0' and p2_hit = '1') or
                                   (server_is_p1 = '1' and color_matches(ball_color, not pin_stable(P2_R), not pin_stable(P2_G), not pin_stable(P2_B)) = '1') then
                                    ball_going_right <= '0';
                                    if server_is_p1 = '0' then
                                        ball_color <= hit_color(not pin_stable(P2_R), not pin_stable(P2_G), not pin_stable(P2_B));
                                    end if;
                                    if move_period > MIN_MOVE_PERIOD then
                                        move_period <= move_period - 1;
                                    end if;
                                elsif ball_pos = NUM_LEDS - 1 then
                                    miss_side <= '1';
                                    game_state <= ST_MISS_FLASH;
                                    flash_timer <= 0;
                                    flash_halves_done <= 0;
                                    flash_on <= '1';
                                    if score_p1 < 99 then
                                        score_p1 <= score_p1 + 1;
                                    end if;
                                    score_toggle <= not score_toggle;
                                else
                                    ball_pos <= ball_pos + 1; -- still time to react
                                end if;
                            else
                                if ball_going_right = '1' then
                                    ball_pos <= ball_pos + 1;
                                else
                                    ball_pos <= ball_pos - 1;
                                end if;
                            end if;
                        else
                            move_tick_counter <= move_tick_counter + 1;
                        end if;

                    when ST_MISS_FLASH =>
                        if flash_timer = FLASH_HALF_PERIOD - 1 then
                            flash_timer <= 0;
                            flash_on <= not flash_on;
                            if flash_halves_done = FLASH_HALVES - 1 then
                                flash_halves_done <= 0;
                                -- Whoever just scored (i.e. didn't miss) serves the next rally
                                if miss_side = '1' then
                                    server_is_p1 <= '1';
                                else
                                    server_is_p1 <= '0';
                                end if;
                                if score_p1 = WIN_SCORE or score_p2 = WIN_SCORE then
                                    game_state <= ST_GAME_OVER;
                                else
                                    -- Wait for any button before serving the next round
                                    game_state <= ST_ROUND_READY;
                                end if;
                            else
                                flash_halves_done <= flash_halves_done + 1;
                            end if;
                        else
                            flash_timer <= flash_timer + 1;
                        end if;

                    when ST_ROUND_READY =>
                        -- Only the point's winner (now the server) can launch the next rally,
                        -- and the button they press sets the new ball color
                        if server_is_p1 = '1' and p1_hit = '1' then
                            ball_pos <= 0;
                            ball_going_right <= '1';
                            ball_color <= hit_color(not pin_stable(P1_R), not pin_stable(P1_G), not pin_stable(P1_B));
                            move_period <= INITIAL_MOVE_PERIOD;
                            move_tick_counter <= 0;
                            game_state <= ST_PLAY;
                        elsif server_is_p1 = '0' and p2_hit = '1' then
                            ball_pos <= NUM_LEDS - 1;
                            ball_going_right <= '0';
                            ball_color <= hit_color(not pin_stable(P2_R), not pin_stable(P2_G), not pin_stable(P2_B));
                            move_period <= INITIAL_MOVE_PERIOD;
                            move_tick_counter <= 0;
                            game_state <= ST_PLAY;
                        end if;

                    when ST_GAME_OVER =>
                        -- Only the winner (the recorded server) can serve the next game
                        if server_is_p1 = '1' and p1_hit = '1' then
                            score_p1 <= 0;
                            score_p2 <= 0;
                            ball_pos <= 0;
                            ball_going_right <= '1';
                            ball_color <= hit_color(not pin_stable(P1_R), not pin_stable(P1_G), not pin_stable(P1_B));
                            move_period <= INITIAL_MOVE_PERIOD;
                            move_tick_counter <= 0;
                            score_toggle <= not score_toggle;
                            game_state <= ST_PLAY;
                        elsif server_is_p1 = '0' and p2_hit = '1' then
                            score_p1 <= 0;
                            score_p2 <= 0;
                            ball_pos <= NUM_LEDS - 1;
                            ball_going_right <= '0';
                            ball_color <= hit_color(not pin_stable(P2_R), not pin_stable(P2_G), not pin_stable(P2_B));
                            move_period <= INITIAL_MOVE_PERIOD;
                            move_tick_counter <= 0;
                            score_toggle <= not score_toggle;
                            game_state <= ST_PLAY;
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- Process 2: WS2812 serial driver
    process(clk)
    begin
        if rising_edge(clk) then
            case ws_state is
                when ST_RESET =>
                    ws2812 <= '0';
                    if ws_timer = RESET_CYCLES - 1 then
                        ws_timer <= 0;
                        ws_bit_idx <= 23;
                        ws_led_idx <= 0;
                        ws_color <= court_color(0);
                        if court_color(0)(23) = '1' then
                            ws_high_len <= T1H_CYCLES;
                        else
                            ws_high_len <= T0H_CYCLES;
                        end if;
                        ws_state <= ST_BIT_HIGH;
                    else
                        ws_timer <= ws_timer + 1;
                    end if;

                when ST_BIT_HIGH =>
                    ws2812 <= '1';
                    if ws_timer = ws_high_len - 1 then
                        ws_timer <= 0;
                        ws_state <= ST_BIT_LOW;
                    else
                        ws_timer <= ws_timer + 1;
                    end if;

                when ST_BIT_LOW =>
                    ws2812 <= '0';
                    if ws_timer = BIT_CYCLES - ws_high_len - 1 then
                        ws_timer <= 0;
                        if ws_bit_idx = 0 then
                            if ws_led_idx = NUM_LEDS - 1 then
                                ws_state <= ST_RESET;
                            else
                                ws_led_idx <= ws_led_idx + 1;
                                ws_bit_idx <= 23;
                                ws_color <= court_color(ws_led_idx + 1);
                                if court_color(ws_led_idx + 1)(23) = '1' then
                                    ws_high_len <= T1H_CYCLES;
                                else
                                    ws_high_len <= T0H_CYCLES;
                                end if;
                                ws_state <= ST_BIT_HIGH;
                            end if;
                        else
                            ws_bit_idx <= ws_bit_idx - 1;
                            if ws_color(ws_bit_idx - 1) = '1' then
                                ws_high_len <= T1H_CYCLES;
                            else
                                ws_high_len <= T0H_CYCLES;
                            end if;
                            ws_state <= ST_BIT_HIGH;
                        end if;
                    else
                        ws_timer <= ws_timer + 1;
                    end if;
            end case;
        end if;
    end process;

    -- I2C master + SSD1306 sequencer: runs the init sequence once, then redraws the
    -- score row (128 bytes, page 0) whenever score_changed is raised by the game logic
    process(clk)
    begin
        if rising_edge(clk) then
            case i2c_state is
                when ST_BOOT_DELAY =>
                    scl_low <= '0';
                    sda_low <= '0';
                    if boot_timer = BOOT_DELAY_CYCLES - 1 then
                        i2c_txn <= TXN_INIT;
                        i2c_byte_idx <= 0;
                        i2c_timer <= 0;
                        i2c_state <= ST_I2C_START;
                    else
                        boot_timer <= boot_timer + 1;
                    end if;

                when ST_I2C_START =>
                    -- SCL released (high); pull SDA low to begin the start condition
                    sda_low <= '1';
                    if i2c_timer = I2C_HALF_PERIOD - 1 then
                        i2c_timer <= 0;
                        scl_low <= '1';
                        i2c_bit_idx <= 0;
                        i2c_cur_byte <= seq_byte(i2c_txn, i2c_byte_idx, score_p1, score_p2);
                        i2c_state <= ST_I2C_BIT_LOW;
                    else
                        i2c_timer <= i2c_timer + 1;
                    end if;

                when ST_I2C_BIT_LOW =>
                    -- SCL held low; present the next data bit, or release for the ack bit
                    if i2c_bit_idx = 8 then
                        sda_low <= '0';
                    else
                        sda_low <= not i2c_cur_byte(7 - i2c_bit_idx);
                    end if;
                    if i2c_timer = I2C_HALF_PERIOD - 1 then
                        i2c_timer <= 0;
                        scl_low <= '0'; -- release SCL high; data becomes valid to the slave
                        i2c_state <= ST_I2C_BIT_HIGH;
                    else
                        i2c_timer <= i2c_timer + 1;
                    end if;

                when ST_I2C_BIT_HIGH =>
                    if i2c_timer = I2C_HALF_PERIOD - 1 then
                        i2c_timer <= 0;
                        scl_low <= '1'; -- bring SCL low again for the next bit/byte
                        if i2c_bit_idx = 8 then
                            if i2c_byte_idx = seq_len(i2c_txn) - 1 then
                                i2c_state <= ST_I2C_STOP1;
                            else
                                i2c_byte_idx <= i2c_byte_idx + 1;
                                i2c_bit_idx <= 0;
                                i2c_cur_byte <= seq_byte(i2c_txn, i2c_byte_idx + 1, score_p1, score_p2);
                                i2c_state <= ST_I2C_BIT_LOW;
                            end if;
                        else
                            i2c_bit_idx <= i2c_bit_idx + 1;
                            i2c_state <= ST_I2C_BIT_LOW;
                        end if;
                    else
                        i2c_timer <= i2c_timer + 1;
                    end if;

                when ST_I2C_STOP1 =>
                    -- SCL low; force SDA low, ready to create the stop condition
                    sda_low <= '1';
                    if i2c_timer = I2C_HALF_PERIOD - 1 then
                        i2c_timer <= 0;
                        scl_low <= '0';
                        i2c_state <= ST_I2C_STOP2;
                    else
                        i2c_timer <= i2c_timer + 1;
                    end if;

                when ST_I2C_STOP2 =>
                    if i2c_timer = I2C_HALF_PERIOD - 1 then
                        i2c_timer <= 0;
                        sda_low <= '0'; -- release SDA while SCL is high: stop condition
                        i2c_state <= ST_I2C_STOP3;
                    else
                        i2c_timer <= i2c_timer + 1;
                    end if;

                when ST_I2C_STOP3 =>
                    if i2c_timer = I2C_HALF_PERIOD - 1 then
                        i2c_timer <= 0;
                        if i2c_txn = TXN_INIT then
                            -- draw the initial 0-0 score right after init completes
                            i2c_txn <= TXN_DATA;
                            i2c_byte_idx <= 0;
                            i2c_state <= ST_I2C_START;
                        else
                            i2c_state <= ST_I2C_IDLE;
                        end if;
                    else
                        i2c_timer <= i2c_timer + 1;
                    end if;

                when ST_I2C_IDLE =>
                    if score_toggle /= score_toggle_seen then
                        score_toggle_seen <= score_toggle;
                        i2c_txn <= TXN_DATA;
                        i2c_byte_idx <= 0;
                        i2c_state <= ST_I2C_START;
                    end if;
            end case;
        end if;
    end process;

end Behavioral;
