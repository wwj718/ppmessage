//
//  PPMessageReceiver.m
//  PPComDemo
//
//  Created by Kun Zhao on 9/28/15.
//  Copyright (c) 2015 Yvertical. All rights reserved.
//

#import "PPMessageReceiver.h"
#import "SRWebSocket.h"
#import "PPUser.h"
#import "PPComUtils.h"
#import "PPMessage.h"
#import "PPTxtMediaItem.h"
#import "PPTxtLoader.h"
#import "PPFastLog.h"

@interface PPMessageReceiver () <SRWebSocketDelegate>

typedef NS_ENUM(NSInteger, AutoReconnectState) {
    AutoReconnectStateNull = 0, //null or error
    AutoReconnectStateConnecting = 1, //auto reconnecting...
    AutoReconnectStateDone = 2, //auto reconnect ok
};

@property PPAppInfo *appInfo;

@property SRWebSocket *srWebSocket;
@property PPUser *user;
@property NSString *wsHost;
@property PPCom *client;

@property BOOL autoReconnecting;
@property BOOL socketClose;
@property AutoReconnectState autoReconnectState;
@property NSTimer *autoReconnectTimer;

-(PPMessage*)parseMessage:(NSString*)message;

@end

@interface PPMessageReceiver (SRWebSocketAutoReconnect)

-(void)tryAutoReconnect;
-(void)stopAutoReconnect;
-(void)autoReconnectSelector;

@end

//////////////////////////
// LOGOUT MESSAGE BEGIN //
//////////////////////////
@interface PPMessageReceiver (PPLogoutMessage)

// check message is a `LOGOUT` message
- (BOOL)pp_isLogoutMessage:(NSString *)message;
// dispatch `LOGOUT` message
- (void)pp_onLogoutMessageRecevied:(NSString *)message;

@end

@implementation PPMessageReceiver (PPLogoutMessage)

- (BOOL)pp_isLogoutMessage:(NSString *)message {
    // user not exist
    if (self.client.user == nil || self.client.user.deviceUuid == nil) {
        return NO;
    }

    if ([self.client.utils isNotNull:message]) {
        NSDictionary *messageBody = [self.client.utils jsonStringToDictionary:message];
        // {mt: "SYS", bo: "4590857d-aae1-11e5-9fbd-0c4de9b21073", ms: "LOGOUT"}
        return messageBody != nil &&
            [messageBody[@"mt"] isEqual:@"SYS"] &&
            [messageBody[@"ms"] isEqual:@"LOGOUT"] &&
            [messageBody[@"bo"] isEqual:self.client.user.deviceUuid];
    }

    return NO;
    
}

- (void)pp_onLogoutMessageRecevied:(NSString *)message {
    [self close];
}

@end
//////////////////////////
// LOGOUT MESSAGE END //
//////////////////////////

@implementation PPMessageReceiver

#pragma mark - Initialize Methods

-(instancetype)init:(PPCom*)client appInfo:(PPAppInfo *)app {
    
    if (self = [super initWithClient:client]) {
        _appInfo = app;
        _client = client;
        _socketClose = NO;
        _autoReconnectState = AutoReconnectStateNull;
        _user = client.user;
        _srWebSocket = [[SRWebSocket alloc] init];
        _wsHost = PPWebSocketHost;
        _autoReconnecting = NO;
    }
    return self;
    
}

#pragma mark - Open Methods

-(void)open {
    [self openWithDelegate:nil];
}

-(void)openWithDelegate:(id<PPMessageReceiverDelegate>)delegate {
    _delegate = delegate;
    
    if (_srWebSocket.readyState == SR_CLOSED || _srWebSocket.readyState == SR_CLOSING) {
        _srWebSocket = [[SRWebSocket alloc] init];
    }

    if (_srWebSocket.readyState != SR_OPEN) {
        
        NSURL *url = [NSURL URLWithString:_wsHost];
        NSURLRequest *request = [NSURLRequest requestWithURL:url];
        _srWebSocket = [_srWebSocket initWithURLRequest:request];
        _srWebSocket.delegate = self;
        [_srWebSocket open];
    }
}

-(void)close {
    if (_srWebSocket) {
        _socketClose = YES;
        [_srWebSocket close];
    }
    [self stopAutoReconnect];
}

#pragma mark - SRWebSocketDelegate

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message {
    PPFastLog(@"WebSocket: receiveMessage: %@", message);

    if ([self pp_isLogoutMessage:message]) {
        [self pp_onLogoutMessageRecevied:message];
    } else {
        PPMessage *ppMessage = [self parseMessage:(NSString*)message];
        if (ppMessage) {
            if (self.delegate) {
                [self.delegate didReceiveMessage:ppMessage];
            }
        }      
    }

}

- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
    PPFastLog(@"webSocketOpen");
    
    self.autoReconnectState = AutoReconnectStateDone;
    [self stopAutoReconnect];

    // auth websocket
    NSDictionary *params = @{
        @"type": @"auth",
        @"app_uuid": self.appInfo.appId,
        @"api_token": self.client.api.accessToken,
        @"user_uuid": _user.uuid,
        @"device_uuid": _user.deviceUuid,
        @"is_service_user": @YES
    };
    NSString *jsonString = [_client.utils dictionaryToJsonString:params];
    [webSocket send:jsonString];
    
    if (self.delegate) {
        if ([self.delegate respondsToSelector:@selector(didWebSocketOpen)]) {
            [self.delegate didWebSocketOpen];
        }
    }
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
    PPFastLog(@"SRWebSocket: didFailWithError:%@", [error description]);
    self.autoReconnectState = AutoReconnectStateNull;
    
    if (self.delegate) {
        if ([self.delegate respondsToSelector:@selector(didWebSocketFailWithError:)]) {
            [self.delegate didWebSocketFailWithError:error];
        }
    }
    
    [self tryAutoReconnect];
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    PPFastLog(@"WebSocket: didCloseWithCode:%@, %d", reason, wasClean);
    self.autoReconnectState = AutoReconnectStateNull;
    
    if (self.socketClose && self.delegate) {
        if ([self.delegate respondsToSelector:@selector(didWebSocketClose)]) {
            [self.delegate didWebSocketClose];
        }
    }
    
    // Some error occurs in the server
    if (!self.socketClose) {
        [self tryAutoReconnect];
    }
}

#pragma mark - Receive PPMessage

-(PPMessage*)parseMessage:(NSString*)message {
    if ([self.client.utils isNull:message]) {
        return nil;
    }
    
    NSDictionary *messageDict = [self.client.utils jsonStringToDictionary:message];
    if ([messageDict count] < 2) {
        return nil;
    }
    
    return [PPMessage messageWithClient:self.client body:messageDict];
}

#pragma mark - Auto Reconnect

-(void)tryAutoReconnect {
    if (self.autoReconnectState != AutoReconnectStateNull) {
        PPFastLog(@"self.autoReconnectState:%d", (int)self.autoReconnectState);
        return;
    }
    
    self.autoReconnectState = AutoReconnectStateConnecting;
    if (!_autoReconnectTimer) {
        _autoReconnectTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(autoReconnectSelector) userInfo:nil repeats:YES];
    }
    if (![_autoReconnectTimer isValid]) {
        [_autoReconnectTimer fire];
    }
    _autoReconnecting = YES;
}

-(void)stopAutoReconnect {
    if (_autoReconnectTimer) {
        PPFastLog(@"stop Auto Reconnect");
        if ([_autoReconnectTimer isValid]) {
            [_autoReconnectTimer invalidate];
        }
        _autoReconnectTimer = nil;
    }
    _autoReconnecting = NO;
}

-(void)autoReconnectSelector {
    PPFastLog(@"start an auto reconnect task");
    if (_srWebSocket) {
        [_srWebSocket close];
        _srWebSocket = nil;
    }
    
    PPFastLog(@"start an new SRWebSocket");
    _srWebSocket = [[SRWebSocket alloc] init];

    [self openWithDelegate:self.delegate];
}

@end
