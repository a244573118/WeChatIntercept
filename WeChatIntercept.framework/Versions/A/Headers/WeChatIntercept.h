//
//  WeChatIntercept.h
//  WeChatIntercept
//
//  Created by 张洋 on 2019/5/30.
//  Copyright © 2019 张洋. All rights reserved.
//

#import <Cocoa/Cocoa.h>

//! Project version number for WeChatIntercept.
FOUNDATION_EXPORT double WeChatInterceptVersionNumber;

//! Project version string for WeChatIntercept.
FOUNDATION_EXPORT const unsigned char WeChatInterceptVersionString[];

// In this header, you should import all the public headers of your framework using statements like #import <WeChatIntercept/PublicHeader.h>
@interface MessageData : NSObject
- (id)initWithMsgType:(long long)arg1;
    @property(retain, nonatomic) NSString *fromUsrName;
    @property(retain, nonatomic) NSString *toUsrName;
    @property(retain, nonatomic) NSString *msgContent;
    @property(retain, nonatomic) NSString *msgPushContent;
    @property(nonatomic) int messageType;
    @property(nonatomic) int msgStatus;
    @property(nonatomic) int msgCreateTime;
    @property(nonatomic) int mesLocalID;
    @property(nonatomic) long long mesSvrID;
    @property(retain, nonatomic) NSString *msgVoiceText;
    @property(copy, nonatomic) NSString *m_nsEmoticonMD5;
- (BOOL)isChatRoomMessage;
- (NSString *)groupChatSenderDisplayName;
- (id)getRealMessageContent;
- (id)getChatRoomUsrName;
- (BOOL)isSendFromSelf;
- (BOOL)isCustomEmojiMsg;
- (BOOL)isImgMsg;
- (BOOL)isVideoMsg;
- (BOOL)isVoiceMsg;
- (BOOL)canForward;
- (BOOL)IsPlayingSound;
- (id)summaryString:(BOOL)arg1;
- (BOOL)isEmojiAppMsg;
- (BOOL)isAppBrandMsg;
- (BOOL)IsUnPlayed;
- (void)SetPlayed;
    @property(retain, nonatomic) NSString *m_nsTitle;
- (id)originalImageFilePath;
    @property(retain, nonatomic) NSString *m_nsVideoPath;
    @property(retain, nonatomic) NSString *m_nsFilePath;
    @property(retain, nonatomic) NSString *m_nsAppMediaUrl;
    @property(nonatomic) MessageData *m_refMessageData;
    @property(nonatomic) unsigned int m_uiDownloadStatus;
- (void)SetPlayingSoundStatus:(BOOL)arg1;
    @end
@interface MessageService : NSObject
- (void)onRevokeMsg:(id)arg1;
- (void)FFToNameFavChatZZ:(id)arg1;
- (void)OnSyncBatchAddMsgs:(NSArray *)arg1 isFirstSync:(BOOL)arg2;
- (void)FFImgToOnFavInfoInfoVCZZ:(id)arg1 isFirstSync:(BOOL)arg2;
- (id)SendTextMessage:(id)arg1 toUsrName:(id)arg2 msgText:(id)arg3 atUserList:(id)arg4;
- (id)GetMsgData:(id)arg1 svrId:(long)arg2;
- (void)AddLocalMsg:(id)arg1 msgData:(id)arg2;
- (void)TranscribeVoiceMessage:(id)arg1 completion:(void (^)(void))arg2;
- (BOOL)ClearUnRead:(id)arg1 FromID:(unsigned int)arg2 ToID:(unsigned int)arg3;
- (BOOL)ClearUnRead:(id)arg1 FromCreateTime:(unsigned int)arg2 ToCreateTime:(unsigned int)arg3;
- (BOOL)hasMsgInChat:(id)arg1;
- (id)GetMsgListWithChatName:(id)arg1 fromLocalId:(unsigned int)arg2 limitCnt:(NSInteger)arg3 hasMore:(char *)arg4 sortAscend:(BOOL)arg5;
- (id)GetMsgListWithChatName:(id)arg1 fromCreateTime:(unsigned int)arg2 limitCnt:(NSInteger)arg3 hasMore:(char *)arg4 sortAscend:(BOOL)arg5;
    @end

@interface MMServiceCenter : NSObject
+ (id)defaultCenter;
- (id)getService:(Class)arg1;
    @end
@interface XMLDictionaryParser : NSObject
+ (id)sharedInstance;
- (id)dictionaryWithString:(id)arg1;
    @end

