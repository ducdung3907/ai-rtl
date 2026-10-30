# Pins from the QMTECH Wukong V3 schematic (V03-20240121)

# 50 MHz oscillator on M21 (not a clock-capable pin, so allow general routing)
set_property PACKAGE_PIN M21 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

# KEY0 (SW2): pull-up, pressed = 0, used as active-low reset
set_property PACKAGE_PIN H7 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

# CH340N USB-UART, directions from the FPGA's point of view
set_property PACKAGE_PIN F3 [get_ports uart_rx]   ;# from CH340N TXD
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
set_property PACKAGE_PIN E3 [get_ports uart_tx]   ;# to CH340N RXD
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

# User LEDs D5/D6: active low (0 = on)
set_property PACKAGE_PIN G21 [get_ports {led[0]}]
set_property PACKAGE_PIN G20 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

# Configuration from SPI flash, quad mode (as in QMTECH's examples)
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]