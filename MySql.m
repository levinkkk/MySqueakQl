//
//  MySql.m
//
//  Created by Ciaran on 01/02/2012.
//  Copyright (c) 2012 Ciaran Jessup. All rights reserved.
//

#import "MySql.h"
#include "sha.h"

@implementation MySql
@synthesize packetNumber,input,output;

-(NSData *) readPacket {
    NSMutableData* packet= [[NSMutableData alloc] initWithCapacity:30000];
    [packet retain];
    
    uint8_t buffer[4096];
    long rc1;
    rc1= [input read:buffer maxLength:4];
    assert(rc1 == 4);
    uint32_t packet_size= buffer[0] + (buffer[1]<<8) + (buffer[2] << 16);
    packetNumber= buffer[3]+1;
    NSLog(@"RECVD Packet Number : %d of size %ul", packetNumber, packet_size);

    uint32_t readSoFar= 0;
    do {
        rc1= [input read:buffer maxLength:( readSoFar+4096>packet_size?(packet_size-readSoFar):4096)];
        readSoFar+= rc1;
        
        if( rc1 > 0 ) {
            [packet appendBytes:buffer length:rc1];
        }
    }
    while( rc1 > 0 && readSoFar<packet_size );  
    
    assert( readSoFar == packet_size);
    
    return packet;
    
}

-(void) sendUint32: (UInt32)value toStream:(NSOutputStream*)stream {
    uint8_t val= value & 0xFF;
    long rc1;
    rc1= [stream write: &val maxLength:1];
    assert(rc1 == 1);
    val= (value & 0xFF00)>>8;
    rc1= [stream write: &val maxLength:1];
    assert(rc1 == 1);
    val= (value & 0xFF0000)>>16;
    rc1=[stream write: &val maxLength:1];
    assert(rc1 == 1);
}

-(void) sendPacket:(NSData*)packet {
    //todo ensure not bigger than 16M (I suspect we'll have overflows in the next line : )
    
    [self sendUint32:(UInt32)[packet length] toStream:output];
    
    int rc1= [output write:&packetNumber maxLength:1];
    assert( rc1 == 1 );
    rc1= [output write:[packet bytes] maxLength:[packet length]];
    assert( rc1 == [packet length] );

    NSLog(@"Sent Packet Number : %d of size %ul", packetNumber,[packet length]);
}

-(void) handshakeForUserName:(NSString*)user password:(NSString*)password {
    NSData* handshakeInitialisationPacket= [self readPacket];
    NSMutableData *scrambleBuffer= [[NSMutableData alloc] initWithCapacity:100];

    UInt8* byteData= (UInt8*)[handshakeInitialisationPacket bytes];
    UInt8 protcol_version= *(byteData++);
    NSString* server_version= [[NSString alloc] initWithCString: (const char*)byteData
                                                  encoding:NSASCIIStringEncoding];
    byteData+=[server_version length]+1; // assumes 1byteperchar [ascii]
    byteData+=4; // Skip the thread_id
    [scrambleBuffer appendBytes:byteData length:8];
    byteData+=8;
    assert(*byteData++ == 0 ); //filler check.

    UInt32 server_capabilities= ( ((*byteData)<<8) + *(byteData+1));
    byteData+=2;
    UInt8 server_language= *byteData;
    byteData+=2; // Skip  server_status;
    server_capabilities= server_capabilities + ( ((*byteData)<<16) + ((*(byteData+1))<<24));
    byteData+=14; // Skip the fller, scramble length etc.

    // hard-coded 12 here is wrong, should scan upto the null pointer end.
    [scrambleBuffer appendBytes:byteData length:12];
    byteData+=13;
    assert( *byteData == 0 );

    [handshakeInitialisationPacket release];
    NSLog(@"Handshaking to Server Version '%@' using Protocol version: %d Language: %d", server_version, protcol_version, server_language);
    
    NSMutableData *client_auth_packet= [[NSMutableData alloc] initWithCapacity:100];
    [client_auth_packet retain];
     UInt32 client_capabilities= server_capabilities;
    client_capabilities= client_capabilities &~ 8; // Not specifying database on connection.
     client_capabilities= client_capabilities &~ 32; // Do not use compression
    client_capabilities= client_capabilities &~ 64; // this is not an odbc client
     client_capabilities= client_capabilities &~ 1024; // this is not an interactive session
     client_capabilities= client_capabilities &~ 2048; // do not switch to ssl    
    client_capabilities= client_capabilities | 512; // new 4.1 protocol
    client_capabilities= client_capabilities | 32768; // New 4.1 authentication
    
    
     uint8_t val= client_capabilities & 0xFF;
     [client_auth_packet appendBytes:&val length:1];
     val= (client_capabilities & 0xFF00)>>8;
     [client_auth_packet appendBytes:&val length:1];
     val= (client_capabilities & 0xFF0000)>>16;
     [client_auth_packet appendBytes:&val length:1];
     val= (client_capabilities & 0xFF000000)>>24;
     [client_auth_packet appendBytes:&val length:1];
     
     UInt32 max_packet_size= 65536;
     val= max_packet_size & 0xFF;
     [client_auth_packet appendBytes:&val length:1];
     val= (max_packet_size & 0xFF00)>>8;
     [client_auth_packet appendBytes:&val length:1];
     val= (max_packet_size & 0xFF0000)>>16;
     [client_auth_packet appendBytes:&val length:1];
     val= (max_packet_size & 0xFF000000)>>24;
     [client_auth_packet appendBytes:&val length:1];    
     
     [client_auth_packet appendBytes:&server_language length:1];    
     val=0;
     int i=0;
     for(i=0;i<23;i++) {
         [client_auth_packet appendBytes:&val length:1];        
     } 
     const char* user_c_str= [user cStringUsingEncoding:NSASCIIStringEncoding];
     [client_auth_packet appendBytes:user_c_str length:strlen(user_c_str)];
     [client_auth_packet appendBytes:&val length:1];        

    SHA_CTX context;
    unsigned char stage1[SHA_DIGEST_LENGTH];
    unsigned char stage2[SHA_DIGEST_LENGTH];
    unsigned char stage3[SHA_DIGEST_LENGTH];
    memset(stage1, 0, SHA_DIGEST_LENGTH);
    memset(stage2, 0, SHA_DIGEST_LENGTH);
    memset(stage3, 0, SHA_DIGEST_LENGTH);
    const char* cstr_password=[password cStringUsingEncoding:NSASCIIStringEncoding]; // No idea if mysql alows non ascii passwords *sob*
    
    SHA1_Init(&context);
    SHA1_Update(&context, cstr_password, strlen(cstr_password));
    SHA1_Final(stage1, &context);

    SHA1_Init(&context);
    SHA1_Update(&context, stage1, SHA_DIGEST_LENGTH);
    SHA1_Final(stage2, &context);

    SHA1_Init(&context);    
    SHA1_Update(&context,[scrambleBuffer bytes], [scrambleBuffer length]);
    SHA1_Update(&context, stage2, SHA_DIGEST_LENGTH);
    SHA1_Final(stage3, &context);
    
    unsigned char token[SHA_DIGEST_LENGTH];
    for(i= 0;i< SHA_DIGEST_LENGTH;i++) {
        token[i]= stage3[i]^stage1[i];
    }
    
    val=SHA_DIGEST_LENGTH;
    [client_auth_packet appendBytes:&val length:1];
    [client_auth_packet appendBytes:&token length:SHA_DIGEST_LENGTH];

    [self sendPacket:client_auth_packet];
    [client_auth_packet release];
    NSData* okOrErrorPacket= [self readPacket];
    UInt8* resultPacketData= (UInt8*)[okOrErrorPacket bytes];
    if( resultPacketData[0] == 0xFF ) {
        uint16_t errorNumber= resultPacketData[1] + (resultPacketData[2]<<8);
        // sqlstate is chars 3-> 8
        
        NSString* errorMessage= [[NSString alloc] initWithCString: (const char*)(resultPacketData+9) encoding:NSASCIIStringEncoding];
        
        NSLog(@"ERROR: %@ (%u)", errorMessage, errorNumber);
        for(int i=0;i< [okOrErrorPacket length]; i++ ) {
            fprintf(stderr, "%x ", resultPacketData[i]);
        }
    }
    else {
           NSLog(@"HAPPPY PACKET");
        
    }
    
    NSString* meh= [[NSString alloc] initWithData:okOrErrorPacket encoding:NSASCIIStringEncoding];
    NSLog(@"%@", meh);
    
}

-(void) sendCommand:(UInt8)command data:(NSData*)data {
    packetNumber= 0; // Reset the packet number
    NSMutableData* dataToSend= [[NSMutableData alloc] initWithBytes:&command length:1];
    if ( data != NULL ) {
        [dataToSend appendData:data];
    }
    [self sendPacket:dataToSend];
}

-(id) initWithHost:(NSString *)host port:(int)port user:(NSString *)user password:(NSString *)password {
    self = [super init];
    if (self) {
        CFReadStreamRef readStream;
        CFWriteStreamRef writeStream;
        CFStreamCreatePairWithSocketToHost(NULL, (CFStringRef)host, port, &readStream, &writeStream);
        //TODO: assert that both readStream + writeSTream are non-null
        
        self.input= (NSInputStream*)readStream;
        self.output=(NSOutputStream*)writeStream;
        [[self input] open];
        [[self output] open]; 

        [self handshakeForUserName:user
                          password:password];
    }
    return self;
}

-(void) quit {
    NSLog(@"Quit");    
    [self sendCommand:1 data:NULL];
    [input close];
    [output close];
    [input release];
    [output release];
    input= NULL;
    output= NULL;
}

-(void) selectDatabase:(NSString*)database {
    NSLog(@"Select Database");    
    NSData* data=[database dataUsingEncoding:NSUTF8StringEncoding];
    [self sendCommand:2 data:data];
    NSData* okOrErrorPacket= [self readPacket];
    UInt8* resultPacketData= (UInt8*)[okOrErrorPacket bytes];
    if( resultPacketData[0] == 0xFF ) {
        uint16_t errorNumber= resultPacketData[1] + (resultPacketData[2]<<8);
        // sqlstate is chars 3-> 8
        
        NSString* errorMessage= [[NSString alloc] initWithCString: (const char*)(resultPacketData+9) encoding:NSASCIIStringEncoding];
        
        NSLog(@"ERROR: %@ (%u)", errorMessage, errorNumber);
        for(int i=0;i< [okOrErrorPacket length]; i++ ) {
            fprintf(stderr, "%x ", resultPacketData[i]);
        }
    }
    else {
        NSLog(@"HAPPPY PACKET");
        
    }
    
    NSString* meh= [[NSString alloc] initWithData:okOrErrorPacket encoding:NSASCIIStringEncoding];
    NSLog(@"%@", meh);    
}

-(void) performQuery:(NSString*)query {
    NSLog(@"Execute Query");
    NSData* data=[query dataUsingEncoding:NSUTF8StringEncoding];
    [self sendCommand:3 data:data];
    NSData* okOrErrorPacket= [self readPacket];
    UInt8* resultPacketData= (UInt8*)[okOrErrorPacket bytes];
    if( resultPacketData[0] == 0xFF ) {
        uint16_t errorNumber= resultPacketData[1] + (resultPacketData[2]<<8);
        // sqlstate is chars 3-> 8
        
        NSString* errorMessage= [[NSString alloc] initWithCString: (const char*)(resultPacketData+9) encoding:NSASCIIStringEncoding];
        
        NSLog(@"ERROR: %@ (%u)", errorMessage, errorNumber);
    }
    else {
        NSLog(@"HAPPPY PACKET");
        NSData *resultSetHeaderPacket= okOrErrorPacket;
        [resultSetHeaderPacket retain];
        UInt8 fieldCount= *((unsigned char*)[resultSetHeaderPacket bytes]);
        NSLog(@"Found %d fields...",fieldCount);
        NSData* fieldDescriptor= [self readPacket];
        while( ![self isEOFPacket: fieldDescriptor ] ) {
   //         NSLog(@"Read a field."); 
            fieldDescriptor= [self readPacket];
        }
        
        NSData* rowDataPacket= [self readPacket];
        while( ![self isEOFPacket: rowDataPacket ] ) {
    //        NSLog(@"Read a RowPacket."); 
            rowDataPacket= [self readPacket];
        }

        [resultSetHeaderPacket release];
 
    }
    for(int i=0;i< [okOrErrorPacket length]; i++ ) {
        fprintf(stderr, "%x ", resultPacketData[i]);
    }
    fprintf(stderr, "\n");
}

-(bool) isEOFPacket:(NSData*)data {
    return *((unsigned char*)[data bytes]) == 0xFE && [data length] < 9;
}

@end
