// Serial Hello: sends a message to your computer once per second.
// Open the serial monitor at 9600 baud to read it.

unsigned long count = 0;

void setup() {
  Serial.begin(9600);  // start the serial connection at 9600 bits per second
}

void loop() {
  Serial.print("Hello from your board! Count: ");
  Serial.println(count);
  count++;
  delay(1000);
}
