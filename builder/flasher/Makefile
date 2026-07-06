# Default settings
PORT ?= /dev/ttyUSB0
BAUD ?= 115200
FLASH_MODE ?= dout
FLASH_SIZE ?= 1MB

.PHONY: flash

# Pattern rule: Allows 'make 9999996' to set SERIAL=9999996
%:
	@$(MAKE) flash SERIAL=$@

# Flash logic
flash:
	@if [ -z "$(SERIAL)" ]; then \
		echo "Error: You must provide a serial number, e.g., 'make 9999996'"; \
		exit 1; \
	fi
	@echo "Flashing multi-segment firmware for serial: $(SERIAL)"
	esptool.py --port $(PORT) --baud $(BAUD) --chip esp8266 \
		write_flash --flash_mode $(FLASH_MODE) --flash_size $(FLASH_SIZE) \
		0x00000 /firmware/$(SERIAL)/latest/0x00000.bin \
		0x10000 /firmware/$(SERIAL)/latest/0x10000.bin \
		0x60000 /firmware/$(SERIAL)/latest/webpages.espfs \
		0xFC000 /firmware/$(SERIAL)/latest/esp_init_data_default_112th_byte_0x03.bin \
		0xFE000 /firmware/$(SERIAL)/latest/blank.bin
