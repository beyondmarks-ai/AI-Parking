# ESP32 plate and fine LCD receiver

This sketch receives `RESULT|<plate>|<fineAmount>` on camera UART (RX GPIO16,
9600 baud) or USB serial (115200 baud). It displays the plate on row 1 and
`Fine Rs <amount>` or `NO FINE` on row 2 of a 16x2 HD44780 I2C LCD.
At startup it shows `PARKGUARD READY` / `Waiting camera`; no fake plate is shown.
Share ground with the camera. Its result-transmit pin must connect to GPIO16.

Connect the hardware with power disconnected:

| LCD | ESP32 DevKit |
| --- | --- |
| GND | GND |
| VCC | 5V/VIN |
| SDA | GPIO 21 |
| SCL | GPIO 22 |

Many LCD backpacks pull SDA and SCL up to 5 V, while ESP32 GPIO is 3.3 V
only. For a permanent circuit, place a bidirectional I2C level shifter between
the LCD and ESP32 (or otherwise ensure the bus pull-ups are to 3.3 V).

The sketch uses Bill Perry's `hd44780` library and automatically detects the
common I2C backpack address (usually `0x27` or `0x3F`). Adjust the small
contrast potentiometer on the LCD backpack if its backlight is on but no text
is visible.

Compile and upload with:

```powershell
arduino-cli compile --fqbn esp32:esp32:esp32 firmware/Esp32LcdHello
arduino-cli upload --fqbn esp32:esp32:esp32 --port COM6 firmware/Esp32LcdHello
```

Use the actual ESP32 port if it is not `COM6`.

Before the image-analyzer update, COM6 was identified as ESP32-D0WD-V3 with
MAC `20:50:0d:4e:62:94`. Its previous 4 MB flash image was backed up at
`output/firmware-backups/COM6-before-image-analyzer-20261012.bin` for recovery.
