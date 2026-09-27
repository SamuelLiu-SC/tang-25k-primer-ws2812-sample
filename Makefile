SHELL := /bin/bash

PROJECT := led_prj
GPRJ := $(PROJECT).gprj

#-r 1 

# Override this on the command line if needed:
# make build GOWIN_HOME=/path/to/Gowin/IDE
GOWIN_HOME ?= /home/lincoln/FPGA/gowin/Gowin_V1.9.11.03_Education_Linux/IDE
GW_SH := $(GOWIN_HOME)/bin/gw_sh
LD_PRELOAD_LIB ?= /lib/x86_64-linux-gnu/libfreetype.so.6

PROGRAMMER_HOME ?= /home/lincoln/FPGA/gowin/Gowin_V1.9.11.03_Education_Linux/Programmer
PROGRAMMER_CLI := $(PROGRAMMER_HOME)/bin/programmer_cli
BITSTREAM := impl/pnr/$(PROJECT).fs
DEVICE ?= GW5A-25A
PROG_OP ?= 2
PROG_CABLE_INDEX ?= 1

RUN_TCL := .gowin_run.tcl

.PHONY: all build syn pnr clean help scan-cables scan-devices prog download download-to-flash erase-flash

all: build

help:
	@echo "Targets:"
	@echo "  make build   - Run synthesis + PNR + bitstream generation"
	@echo "  make syn     - Run synthesis only"
	@echo "  make pnr     - Run place and route (expects synthesis output)"
	@echo "  make scan-cables  - List connected Gowin programmer cables"
	@echo "  make scan-devices - Scan JTAG chain for FPGA devices"
	@echo "  make prog    - Program $(BITSTREAM) to FPGA SRAM (requires sudo)"
	@echo "  make download - Download $(BITSTREAM) to FPGA SRAM (with sudo)"
	@echo "  make download-to-flash - Download $(BITSTREAM) to FPGA flash (with sudo)"
	@echo "  make clean   - Remove generated synthesis/PNR outputs"
	@echo ""
	@echo "Notes:"
	@echo "  - SRAM boots first if available (survives power cycle with USB attached)"
	@echo "  - To test flash boot: use download-to-flash, then fully power cycle (remove USB)"
	@echo "  - For flash-only boot: open project in Gowin IDE to configure boot priority"
	@echo ""
	@echo "Variables:"
	@echo "  GOWIN_HOME=<path to Gowin IDE>"
	@echo "  PROGRAMMER_HOME=<path to Gowin Programmer>"
	@echo "  DEVICE=<GW5A-25A|...>"
	@echo "  PROG_OP=<2 for SRAM Program, 1 for Reprogram flash>"
	@echo "  PROG_CABLE_INDEX=<0..5>"
	@echo "  LD_PRELOAD_LIB=<path to libfreetype.so.6>"

build:
	@test -f "$(GPRJ)" || { echo "Missing project file: $(GPRJ)"; exit 1; }
	@test -x "$(GW_SH)" || { echo "gw_sh not found: $(GW_SH)"; exit 1; }
	@printf "open_project %s\nrun all\nexit\n" "$(GPRJ)" > "$(RUN_TCL)"
	@GOWIN_HOME="$(GOWIN_HOME)" \
	LD_LIBRARY_PATH="$(GOWIN_HOME)/lib:$$LD_LIBRARY_PATH" \
	QT_QPA_PLATFORM=offscreen \
	LD_PRELOAD="$(LD_PRELOAD_LIB)" \
	"$(GW_SH)" "$(RUN_TCL)"

syn:
	@test -f "$(GPRJ)" || { echo "Missing project file: $(GPRJ)"; exit 1; }
	@test -x "$(GW_SH)" || { echo "gw_sh not found: $(GW_SH)"; exit 1; }
	@printf "open_project %s\nrun syn\nexit\n" "$(GPRJ)" > "$(RUN_TCL)"
	@GOWIN_HOME="$(GOWIN_HOME)" \
	LD_LIBRARY_PATH="$(GOWIN_HOME)/lib:$$LD_LIBRARY_PATH" \
	QT_QPA_PLATFORM=offscreen \
	LD_PRELOAD="$(LD_PRELOAD_LIB)" \
	"$(GW_SH)" "$(RUN_TCL)"

pnr:
	@test -f "$(GPRJ)" || { echo "Missing project file: $(GPRJ)"; exit 1; }
	@test -x "$(GW_SH)" || { echo "gw_sh not found: $(GW_SH)"; exit 1; }
	@printf "open_project %s\nrun pnr\nexit\n" "$(GPRJ)" > "$(RUN_TCL)"
	@GOWIN_HOME="$(GOWIN_HOME)" \
	LD_LIBRARY_PATH="$(GOWIN_HOME)/lib:$$LD_LIBRARY_PATH" \
	QT_QPA_PLATFORM=offscreen \
	LD_PRELOAD="$(LD_PRELOAD_LIB)" \
	"$(GW_SH)" "$(RUN_TCL)"

scan-cables:
	@test -x "$(PROGRAMMER_CLI)" || { echo "programmer_cli not found: $(PROGRAMMER_CLI)"; exit 1; }
	@"$(PROGRAMMER_CLI)" --scan-cables

scan-devices:
	@test -x "$(PROGRAMMER_CLI)" || { echo "programmer_cli not found: $(PROGRAMMER_CLI)"; exit 1; }
	@"$(PROGRAMMER_CLI)" --cable-index "$(PROG_CABLE_INDEX)" --scan

prog: $(BITSTREAM)
	@test -x "$(PROGRAMMER_CLI)" || { echo "programmer_cli not found: $(PROGRAMMER_CLI)"; exit 1; }
	@"$(PROGRAMMER_CLI)" \
		-d "$(DEVICE)" \
		-r "$(PROG_OP)" \
		--cable-index "$(PROG_CABLE_INDEX)" \
		-f "$(abspath $(BITSTREAM))"

download: $(BITSTREAM)
	@test -x "$(PROGRAMMER_CLI)" || { echo "programmer_cli not found: $(PROGRAMMER_CLI)"; exit 1; }
	sudo "$(PROGRAMMER_CLI)" \
		-d "$(DEVICE)" \
		-r "$(PROG_OP)" \
		--cable-index "$(PROG_CABLE_INDEX)" \
		-f "$(abspath $(BITSTREAM))"

download-to-flash: $(BITSTREAM)
	@test -x "$(PROGRAMMER_CLI)" || { echo "programmer_cli not found: $(PROGRAMMER_CLI)"; exit 1; }
	sudo "$(PROGRAMMER_CLI)" \
		-d "$(DEVICE)" \
		-r 1 \
		--cable-index "$(PROG_CABLE_INDEX)" \
		-f "$(abspath $(BITSTREAM))"





erase-flash:
	@test -x "$(PROGRAMMER_CLI)" || { echo "programmer_cli not found: $(PROGRAMMER_CLI)"; exit 1; }
	@echo "Erasing embedded flash..."
	sudo "$(PROGRAMMER_CLI)" \
		-d "$(DEVICE)" \
		-r 7 \
		--cable-index "$(PROG_CABLE_INDEX)"


openfpgaloader:
	openFPGALoader  -b tangnano $(BITSTREAM) 

openfpgaloader-flash:
	openFPGALoader  -b tangnano --write-flash $(BITSTREAM)

clean:
	@rm -rf impl/gwsynthesis impl/pnr "$(RUN_TCL)"
	@echo "Cleaned synthesis/PNR outputs"