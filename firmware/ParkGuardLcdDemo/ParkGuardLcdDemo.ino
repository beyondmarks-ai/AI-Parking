#include <Wire.h>
#include <SoftwareSerial.h>
#include <hd44780.h>
#include <hd44780ioClass/hd44780_I2Cexp.h>

// Arduino Uno: LCD SDA -> A4, SCL -> A5, VCC -> 5V, GND -> GND.
// Detect the I2C backpack address and pin mapping automatically.
hd44780_I2Cexp lcd;
SoftwareSerial espLink(2, 3);  // RX=D2 from ESP32 GPIO14; D3 TX is unused.
bool displayReady = false;
unsigned long lastAttempt = 0;
char inputLine[40];
byte inputLength = 0;

bool initializeDisplay() {
  const int status = lcd.begin(16, 2);
  if (status != 0) {
    Serial.print(F("LCD initialization failed, status="));
    Serial.println(status);
    Serial.println(F("Check SDA=A4, SCL=A5, power and ground."));
    return false;
  }

  lcd.backlight();
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print(F("PARKGUARD READY"));
  lcd.setCursor(0, 1);
  lcd.print(F("Waiting..."));
  displayReady = true;
  Serial.println(F("LCD_READY: waiting for ESP32 results"));
  return true;
}

void displayParkingResult(const char *plate, int fineAmount) {
  if (!displayReady && !initializeDisplay()) return;
  lcd.clear();
  lcd.setCursor(0, 0);
  for (byte index = 0; plate[index] && index < 16; ++index) lcd.print(plate[index]);
  lcd.setCursor(0, 1);
  if (fineAmount > 0) {
    lcd.print(F("Fine Rs "));
    lcd.print(fineAmount);
  } else {
    lcd.print(F("NO FINE"));
  }
  Serial.print(F("LCD_RESULT: "));
  Serial.print(plate);
  Serial.print(F(" / Rs "));
  Serial.println(fineAmount);
}

void processLine() {
  inputLine[inputLength] = '\0';
  if (strncmp(inputLine, "RESULT|", 7) != 0) return;
  char *plate = inputLine + 7;
  char *separator = strchr(plate, '|');
  if (!separator) return;
  *separator = '\0';
  const int fineAmount = atoi(separator + 1);
  displayParkingResult(plate, fineAmount);
}

void setup() {
  Serial.begin(115200);
  espLink.begin(9600);
  Wire.begin();
  // Recover from a stuck I2C bus instead of hanging indefinitely.
  Wire.setWireTimeout(25000, true);
  delay(250);
  initializeDisplay();
  lastAttempt = millis();
}

void loop() {
  while (espLink.available()) {
    const char value = espLink.read();
    if (value == '\n' || value == '\r') {
      if (inputLength > 0) processLine();
      inputLength = 0;
    } else if (inputLength < sizeof(inputLine) - 1) {
      inputLine[inputLength++] = value;
    } else {
      inputLength = 0;
    }
  }
  if (!displayReady && millis() - lastAttempt >= 3000) {
    lastAttempt = millis();
    initializeDisplay();
  }
}
