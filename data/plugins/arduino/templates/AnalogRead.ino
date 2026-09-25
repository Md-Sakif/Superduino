// Analog Read: measures the voltage on pin A0 and prints it.
// Try a potentiometer: outer legs to 5V (or 3.3V) and GND, middle leg to A0.
// Open the serial monitor or plotter at 9600 baud to watch the values.

void setup() {
  Serial.begin(9600);
}

void loop() {
  int value = analogRead(A0);  // 0 .. 1023 on most boards
  Serial.println(value);
  delay(100);
}
