
#include <SPI.h>
#include <SdFat.h>
#include <SdFatUtil.h>
#include <Ethernet.h>
#include <Wire.h>

#include "WebServer.h"
#include "bmp085.h"
/************ ETHERNET STUFF ************/
byte mac[] = { 0x90, 0xA2, 0xDA, 0x00, 0x3C, 0xDF };
byte ip[] = { 10, 20, 1, 2};

#define PREFIX "/"
WebServer webserver(PREFIX, 80);

#define P4A_MAX_FUNCTION_RESPONSE_LENGTH 32

/************ SDCARD STUFF ************/
Sd2Card card;
SdVolume volume;
SdFile root;
SdFile file;

/************* BMP085 stuff **********/
int temperature = 0;
  long pressure = 0;


// store error strings in flash to save RAM
#define error(s) error_P(PSTR(s))

void error_P(const char* str) {
  PgmPrint("error: ");
  SerialPrintln_P(str);
  if (card.errorCode()) {
    PgmPrint("SD error: ");
    Serial.print(card.errorCode(), HEX);
    Serial.print(',');
    Serial.println(card.errorData(), HEX);
  }
  while(1);
}

// Parser has following states:
#define P4A_PARSE_REGULAR 0
#define P4A_PARSE_HASH 1
#define P4A_PARSE_COMMAND 2
//regular - when parsing file and content is being sent to client
//hash - hash sign was encountered - if next char is { we start command mode
//			if not - we output both hash and next char
//command - we search for command and wait for closing }
//
//********************************** TEMPLATE STRUCTURE *************************
//Function parseP4A reads given file from SD card and outputs it's contents to client. 
//Each sequence #{X} where X is lowercase letter replaces with output of function. Functions and
//corresponding letters are associted with lookup array:
//Size of array - alphabeth size. We use lowercase letters as function mnemonics. If we
//use letter 'b' as function name - thus #{b} in template library will use function pointer 
//stored in _fcts array with index _fcts['b' - 'a'] -> _fcts[1]. 
//
//Functions stored in _fcts array should take pointer to char buffer as argument and return no
//value. Result to send to client should be null terminated string stored in buffer. Buffer size
//is defined as P4A_MAX_FUNCTION_RESPONSE_LENGTH
void (*_fcts['z'-'a'])(char *);

//Sample functions 
//Return number of seconds since Arduino start
void timeReport(char *buf) { itoa(millis()/1000, buf, 10); };
//Return current temperature (Word 1.0 style :)) read more in point 5 http://www.joelonsoftware.com/articles/fog0000000043.html )
void tempReport(char *buf) { itoa(22, buf, 10); };

void pressureReport(char *buf) {
	bmp085_read_temperature_and_pressure (&temperature, &pressure);
	itoa(pressure/100.0, buf, 10);
	Serial.print ("temp & press: ");
	Serial.print (temperature/10.0);
	Serial.print(" ");
	Serial.println (pressure/100.0);
	
};

//I guess it should be moved to Webduino library -  buffered output would be helpful for all clients
#define P4A_SEND_BUFFER_SIZE 64
char static P4A_send_buffer[P4A_SEND_BUFFER_SIZE];
short int P4A_send_buffer_index = 0;

//Flush buffer
void flushBuffer(WebServer &server){
		P4A_send_buffer[P4A_send_buffer_index] = 0;
		server.write(P4A_send_buffer,P4A_send_buffer_index);
		P4A_send_buffer_index = 0;
//		Serial.println("flushh");
	
}

//Should be buffer flushed?
void checkBufferForFlush(WebServer &server){
	if (P4A_send_buffer_index >= P4A_SEND_BUFFER_SIZE - 2) {
		flushBuffer(server);
	};
};
	
//Append char to buffer
void bufferedSend ( WebServer &server, char c) {
	checkBufferForFlush(server);
	P4A_send_buffer[P4A_send_buffer_index++] = c;
}

//Append char string to buffer.
//String could be not longer than P4A_SEND_BUFFER_SIZE. 
//
//Worst case: if function will be called when space for one char is left 
//it will add first char from string, flush buffer and copy rest of string to buffer
//not checking if whole remaining string has fitted into buffer (should not overflow 
//buffer :) just truncate response) 
void bufferedSend ( WebServer &server, const char *c , uint8_t size) {
//	Serial.print("idx: ");
//	Serial.println(P4A_send_buffer_index);
	for (int i=0; i<size; i++){
		
		P4A_send_buffer[P4A_send_buffer_index++] = c[i];
		
		if (P4A_send_buffer_index >= P4A_SEND_BUFFER_SIZE - 2) {
			flushBuffer(server);
		}
	}
//	Serial.print("idx after: ");
//	Serial.println(P4A_send_buffer_index);
	}

void bufferedSend ( WebServer &server, const char *c) {
//	Serial.print("BS: ");
//	Serial.println(c);
	bufferedSend(server, c, strlen(c));
}

//******************
//Reads HTML file, parses looking for our macro and sends back to client
int parseP4A( char * filename, WebServer &server ) {
	//simple status
	short int STATUS = P4A_PARSE_REGULAR;
	char c[2];
	c[1] = 0;
	
	
	//buffer to hold response from functions - there is no boundary checking, so
	//function has to not overwrite data
  char buf[P4A_MAX_FUNCTION_RESPONSE_LENGTH];
		
  if (! file.open(&root, filename, O_READ)) {
		return -1;
  }
  while ((file.read(c,1) ) > 0) {
		if (STATUS == P4A_PARSE_REGULAR && c[0] == '#')
		{
			//hash was found we need to inspect next character
			STATUS = P4A_PARSE_HASH;
			continue;
		}
		
		if (STATUS == P4A_PARSE_HASH) {
			if (c[0] == '{') {
				//go to command mode
				STATUS = P4A_PARSE_COMMAND;
				continue;
			} else {
				//fallback to regular mode, but first send pending hash
				STATUS = P4A_PARSE_REGULAR;
				bufferedSend(server, "#");
			}
				
		}
		
		if (STATUS == P4A_PARSE_COMMAND) {
			if(c[0] == '}') {
				STATUS = P4A_PARSE_REGULAR;
				continue;
			};
		  if (c[0] >= 'a' && c[0] <='z') {
				//Command found
				if (_fcts[c[0]-'a'] == NULL) {
					bufferedSend(server,"n/a");
					continue;
				} else {
					//Call function from table
					_fcts[ c[0]-'a'](buf);
					//Write response to client
					bufferedSend( server, buf );
				}
			}
			
		}
			
		
		if (STATUS == P4A_PARSE_REGULAR)
			bufferedSend(server, c);
  }

  //force buffer flushing
  flushBuffer(server);
	file.close();
  return 0;       
}

P(CT_PNG) = "image/png\n";
P(CT_JPG) = "image/jpeg\n";
P(CT_HTML) = "text/html\n";
P(CT_CSS) = "text/css\n";
P(CT_PLAIN) = "text/plain\n";
P(CT) = "Content-type: ";
P(OK) = "HTTP/1.0 200 OK\n";
void fetchSD(WebServer &server, WebServer::ConnectionType type, char *urltail, bool){
	char buf[32];
	int16_t  readed;
	
	++urltail;
	char *dot_index; //Where dot is located
	if (! file.open(&root, urltail, O_READ)) {
		//Real 404
		webserver.httpNotFound();
  } else {
	if (dot_index = strstr(urltail, ".")) {
		++dot_index;
		server.printP(OK);
		server.printP(CT);
		if (!strcmp(dot_index, "htm")) {
				server.printP(CT_HTML);
			
		} else if (!strcmp(dot_index, "css")) {
				server.printP(CT_CSS);
				
		} else if (!strcmp(dot_index, "jpg")) {
				server.printP(CT_JPG);
				
		} else {
				server.printP(CT_PLAIN);
		}
		server.print(CRLF);
	}
	readed = file.read(buf,30);
	while( readed > 0) {
		buf[readed] = 0;
		bufferedSend(server,buf,readed);
		readed = file.read(buf,30);
	}
	flushBuffer(server);
	file.close();
	}
} 
//******* INDEX *************

void index(WebServer &server, WebServer::ConnectionType type, char *, bool){
  server.httpSuccess();
  if (!parseP4A("BARO.HTM", server)) {
		Serial.println("P4A: -1");
	}
};

//void blob(WebServer &server, WebServer::ConnectionType type, char *url, bool b){
//	server.httpSuccess("text/html");
//	fetchSD(server, type, url, b);
//}


//******************* SETUP
void setup() {
  Serial.begin(115200);
  PgmPrint("Free RAM: ");
  Serial.println(FreeRam());  
  
  // initialize the SD card at SPI_HALF_SPEED to avoid bus errors with
  // breadboards.  use SPI_FULL_SPEED for better performance.
  pinMode(10, OUTPUT);                       // set the SS pin as an output (necessary!)
  digitalWrite(10, HIGH);                    // but turn off the W5100 chip!

  if (!card.init(SPI_FULL_SPEED, 4)) error("card.init failed!");
  
  // initialize a FAT volume
  if (!volume.init(&card)) error("vol.init failed!");

  PgmPrint("Volume is FAT");
  Serial.println(volume.fatType(),DEC);
  Serial.println();
  
  if (!root.openRoot(&volume)) error("openRoot failed");

  // list file in root with date and size
  PgmPrintln("Files found in root:");
  root.ls(LS_DATE | LS_SIZE);
  Serial.println();
  
  // Recursive list of all directories
  PgmPrintln("Files found in all dirs:");
  root.ls(LS_R);
  
  Serial.println();
  PgmPrintln("Done");
  
  // Debugging complete, we start the server!
  Ethernet.begin(mac, ip);
  webserver.setDefaultCommand(&index);
	webserver.setFailureCommand(&fetchSD);
//	webserver.addCommand("blob.htm", &blob);

  //Populate opcodes table
  for (int i =0; i<'z'-'a'; i++)
		_fcts[i] = NULL;
	_fcts['m'-'a'] = timeReport;
  _fcts['t'-'a'] = tempReport;
  _fcts['p'-'a'] = pressureReport;
	setupBMP();
	delay(100);
}


//***************** LOOP ***************************************

void loop()
{
 char buff[64];
  int len = 64;
  /* process incoming connections one at a time forever */
  webserver.processConnection(buff, &len);
	
}  

