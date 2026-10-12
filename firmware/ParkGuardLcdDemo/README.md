# LCD fine demonstration

Standalone Arduino Uno sketch for a common 16x2 HD44780 LCD with an I2C
expander backpack. Shows `DEMO FINE` on row 1 and `Rs 500` on row 2 at startup.
The amount is a fixed demonstration value; this sketch does not receive OCR
results or issue a real fine.

With power disconnected, connect LCD SDA to Uno A4, SCL to A5, VCC to 5V,
and GND to GND. The Uno's labelled SDA/SCL header uses these same signals.
Adjust the backpack contrast potentiometer if the backlight is on but text
is invisible.

Uses the `hd44780` library by Bill Perry, with automatic backpack address and
pin mapping detection. Compile with:

```powershell
arduino-cli compile --fqbn arduino:avr:uno firmware/ParkGuardLcdDemo
```

Upload to the verified Uno USB port with `arduino-cli upload --fqbn
arduino:avr:uno --port COM_PORT firmware/ParkGuardLcdDemo`.
Uploading replaces the Uno's running sketch. Serial output at 115200 baud
reports initialization success or an error; visually check the actual LCD.
