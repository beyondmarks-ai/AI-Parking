#include <Wire.h>
#include <hd44780.h>
#include <hd44780ioClass/hd44780_I2Cexp.h>

// ESP32 DevKit -> I2C LCD: SDA=GPIO21, SCL=GPIO22, VCC=5V, GND=GND.
// The hd44780 library detects the LCD backpack address automatically.
constexpr uint8_t LCD_COLUMNS = 16;
constexpr uint8_t LCD_ROWS = 2;
constexpr uint8_t SDA_PIN = 21;
constexpr uint8_t SCL_PIN = 22;
constexpr uint8_t CAMERA_RX_PIN = 16;
constexpr uint32_t CAMERA_BAUD = 9600;

hd44780_I2Cexp lcd;
HardwareSerial cameraLink(2);
bool displayReady = false;
unsigned long lastAttempt = 0;
char inputLine[48];
size_t inputLength = 0;

void showPlate(const char *plate, int fineAmount) {
  if (!displayReady) return;
  lcd.clear();
  lcd.setCursor(0, 0);
  for (size_t index = 0; plate[index] && index < LCD_COLUMNS; ++index) {
    lcd.print(plate[index]);
  }
  lcd.setCursor(0, 1);
  if (fineAmount > 0) {
    lcd.print("Fine Rs ");
    lcd.print(fineAmount);
  } else {
    lcd.print("NO FINE");
  }
  Serial.printf("LCD_RESULT: %s / Rs %d\n", plate, fineAmount);
}

void processCameraLine() {
  inputLine[inputLength] = '\0';
  if (strncmp(inputLine, "RESULT|", 7) != 0) return;

  char *plate = inputLine + 7;
  char *separator = strchr(plate, '|');
  if (separator == nullptr) return;
  *separator = '\0';
  showPlate(plate, atoi(separator + 1));
}

void consumeResultByte(char value) {
  if (value == '\n' || value == '\r') {
    if (inputLength > 0) processCameraLine();
    inputLength = 0;
  } else if (inputLength < sizeof(inputLine) - 1) {
    inputLine[inputLength++] = value;
  } else {
    inputLength = 0;
  }
}

void initializeDisplay() {
  const int status = lcd.begin(LCD_COLUMNS, LCD_ROWS);
  if (status != 0) {
    Serial.printf("LCD initialization failed (status %d); retrying.\n", status);
    return;
  }

  lcd.backlight();
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("PARKGUARD READY");
  lcd.setCursor(0, 1);
  lcd.print("Waiting camera");
  Serial.println("LCD ready; waiting for camera result.");
  displayReady = true;
}

void setup() {
  Serial.begin(115200);
  Wire.begin(SDA_PIN, SCL_PIN);
  cameraLink.begin(CAMERA_BAUD, SERIAL_8N1, CAMERA_RX_PIN, -1);
  initializeDisplay();
  lastAttempt = millis();
}

void loop() {
  while (cameraLink.available()) {
    consumeResultByte(static_cast<char>(cameraLink.read()));
  }
  while (Serial.available()) {
    consumeResultByte(static_cast<char>(Serial.read()));
  }

  if (!displayReady && millis() - lastAttempt >= 3000) {
    lastAttempt = millis();
    initializeDisplay();
  }
}
