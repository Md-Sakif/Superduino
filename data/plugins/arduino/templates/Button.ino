// Button: lights the built-in LED while a push button is pressed.
// Connect a button between pin 2 and GND. No resistor is needed:
// INPUT_PULLUP turns on the board's own pull-up resistor, so the pin
// reads HIGH when the button is released and LOW when it is pressed.

const int BUTTON_PIN = 2;

void setup() {
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(LED_BUILTIN, OUTPUT);
}

void loop() {
  bool pressed = digitalRead(BUTTON_PIN) == LOW;
  digitalWrite(LED_BUILTIN, pressed ? HIGH : LOW);
}
