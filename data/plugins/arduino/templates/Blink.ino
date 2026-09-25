// Blink: turns the built-in LED on and off every second.
// Most boards have a small LED connected to the pin called LED_BUILTIN.

void setup() {
  // The LED pin is an output: the board drives it high or low.
  pinMode(LED_BUILTIN, OUTPUT);
}

void loop() {
  digitalWrite(LED_BUILTIN, HIGH);  // LED on
  delay(1000);                      // wait one second (1000 milliseconds)
  digitalWrite(LED_BUILTIN, LOW);   // LED off
  delay(1000);
}
