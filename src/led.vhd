library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity led is
    Port (
        ws2812 : out STD_LOGIC;
        -- Status inputs shown on the first 6 LEDs, in order: G7, H8, H5, G8, H7, J5
        pin_in : in  STD_LOGIC_VECTOR(5 downto 0)
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

    -- Internal signals tracking registers
    signal counter : unsigned(31 downto 0) := (others => '0');
    signal led_reg : std_logic_vector(2 downto 0) := "110";

    -- WS2812 timing @ ~13.125 MHz clk (76.19ns/cycle)
    constant T0H_CYCLES    : integer := 5;   -- 0.38us
    constant T1H_CYCLES    : integer := 10;  -- 0.76us
    constant BIT_CYCLES    : integer := 16;  -- 1.22us total bit period
    constant RESET_CYCLES  : integer := 4000; -- >300us latch/reset gap (WS2812B-V5 needs >=280us)

    constant NUM_LEDS      : integer := 50; -- LEDs chained on the ws2812 line
    constant NUM_PIN_LEDS  : integer := 6;  -- Leading LEDs that mirror pin_in status

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

    -- Color for a given LED index, evaluated directly (no dependency on the ws_led_idx register)
    function led_color(idx : integer; pins : std_logic_vector(5 downto 0)) return std_logic_vector is
    begin
        if idx < NUM_PIN_LEDS and pins(idx) = '1' then
            return x"FFFFFF";
        else
            return x"000000";
        end if;
    end function;
begin

    u_osca : OSCA
        generic map (FREQ_DIV => 16)
        port map (
            OSCOUT => clk,
            OSCEN  => '1'
        );

    -- Process 1: Counter and LED shifting logic
    process(clk)
    begin
        if rising_edge(clk) then
            if counter < 1750000 then
                counter <= counter + 1;
            else
                counter <= (others => '0');
                -- Rotates the bits left, matching your Verilog {led[1:0], led[2]}
                led_reg <= led_reg(1 downto 0) & led_reg(2);
            end if;
        end if;
    end process;

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
                        ws_color <= led_color(0, pin_stable);
                        if led_color(0, pin_stable)(23) = '1' then
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
                                ws_color <= led_color(ws_led_idx + 1, pin_stable);
                                if led_color(ws_led_idx + 1, pin_stable)(23) = '1' then
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

end Behavioral;
