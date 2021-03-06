//
//  QNResumeUpload.m
//  QiniuSDK
//
//  Created by yangsen on 2020/5/6.
//  Copyright © 2020 Qiniu. All rights reserved.
//

#import "QNDefine.h"
#import "QNResumeUpload.h"
#import "QNResponseInfo.h"
#import "QNRequestTransaction.h"

@interface QNResumeUpload ()

@property (nonatomic, assign) float previousPercent;
@property(nonatomic, strong)QNRequestTransaction *uploadTransaction;

@property(nonatomic, strong)QNResponseInfo *uploadChunkErrorResponseInfo;
@property(nonatomic, strong)NSDictionary *uploadChunkErrorResponse;

@end

@implementation QNResumeUpload

- (void)startToUpload{
    [super startToUpload];
    
    self.previousPercent = 0;
    self.uploadChunkErrorResponseInfo = nil;
    self.uploadChunkErrorResponse = nil;
    
    kQNWeakSelf;
    [self uploadRestChunk:^{
        kQNStrongSelf;
        
        if (![self.uploadFileInfo isAllUploaded]) {
            
            if (self.uploadChunkErrorResponseInfo.couldRetry && [self.config allowBackupHost]) {
                BOOL isSwitched = [self switchRegionAndUpload];
                if (isSwitched == NO) {
                    [self complete:self.uploadChunkErrorResponseInfo response:self.uploadChunkErrorResponse];
                }
            } else {
                [self complete:self.uploadChunkErrorResponseInfo response:self.uploadChunkErrorResponse];
            }
            
        } else {
            
            kQNWeakSelf;
            [self makeFile:^(QNResponseInfo * _Nullable responseInfo, NSDictionary * _Nullable response) {
                kQNStrongSelf;
                
                if (responseInfo.isOK == NO) {
                    if (responseInfo.couldRetry && [self.config allowBackupHost]) {
                        BOOL isSwitched = [self switchRegionAndUpload];
                        if (isSwitched == NO) {
                            [self complete:responseInfo response:response];
                        }
                    } else {
                        [self complete:responseInfo response:response];
                    }
                } else {
                    QNAsyncRunInMain(^{
                        self.option.progressHandler(self.key, 1.0);
                     });
                    [self removeUploadInfoRecord];
                    [self complete:responseInfo response:response];
                }
            }];
        }
    }];
}

- (void)uploadRestChunk:(dispatch_block_t)completeHandler{
    if (!self.uploadFileInfo) {
        [self setErrorResponseInfo:[QNResponseInfo responseInfoWithInvalidArgument:@"regions error"] errorResponse:nil];
        completeHandler();
        return;
    }
    
    id <QNUploadRegion> currentRegion = [self getCurrentRegion];
    if (!currentRegion) {
        [self setErrorResponseInfo:[QNResponseInfo responseInfoWithNoUsableHostError:@"server error"] errorResponse:nil];
        completeHandler();
        return;
    }
    
    QNUploadData *chunk = [self.uploadFileInfo nextUploadData];
    QNUploadBlock *block = chunk ? [self.uploadFileInfo blockWithIndex:chunk.blockIndex] : nil;
    
    kQNWeakSelf;
    void (^progress)(long long, long long) = ^(long long totalBytesWritten, long long totalBytesExpectedToWrite){
        kQNStrongSelf;
        
        chunk.progress = (float)totalBytesWritten / (float)totalBytesExpectedToWrite;
        float percent = self.uploadFileInfo.progress;
        if (percent > 0.95) {
            percent = 0.95;
        }
        if (percent > self.previousPercent) {
            self.previousPercent = percent;
        } else {
            percent = self.previousPercent;
        }
        QNAsyncRunInMain(^{
            self.option.progressHandler(self.key, percent);
        });
    };
    
    if (!chunk) {
        completeHandler();
    } else if (chunk.isFirstData) {
        [self makeBlock:block firstChunk:chunk progress:progress completeHandler:completeHandler];
    } else {
        [self uploadChunk:block chunk:chunk progress:progress completeHandler:completeHandler];
    }
}

- (void)makeBlock:(QNUploadBlock *)block
       firstChunk:(QNUploadData *)chunk
         progress:(void(^)(long long totalBytesWritten, long long totalBytesExpectedToWrite))progress
  completeHandler:(dispatch_block_t)completeHandler{
    
    NSData *chunkData = [self getDataWithChunk:chunk block:block];
    if (chunkData == nil) {
        [self setErrorResponseInfo:[QNResponseInfo responseInfoWithLocalIOError:@"get chunk data error"] errorResponse:nil];
        completeHandler();
        return;
    }
    
    chunk.isUploading = YES;
    chunk.isCompleted = NO;
    
    kQNWeakSelf;
    QNRequestTransaction *transaction = [self createUploadRequestTransaction];
    [transaction makeBlock:block.offset
                 blockSize:block.size
            firstChunkData:chunkData
                  progress:progress
                  complete:^(QNResponseInfo * _Nullable responseInfo, QNUploadRegionRequestMetrics * _Nullable metrics, NSDictionary * _Nullable response) {
        kQNStrongSelf;
        
        [self addRegionRequestMetricsOfOneFlow:metrics];
        
        NSString *blockContext = response[@"ctx"];
        if (responseInfo.isOK && blockContext) {
            block.context = blockContext;
            chunk.isUploading = NO;
            chunk.isCompleted = YES;
            [self recordUploadInfo];
            [self uploadRestChunk:completeHandler];
        } else {
            chunk.isUploading = NO;
            chunk.isCompleted = NO;
            [self setErrorResponseInfo:responseInfo errorResponse:response];
            completeHandler();
        }
    }];
}

- (void)uploadChunk:(QNUploadBlock *)block
              chunk:(QNUploadData *)chunk
           progress:(void(^)(long long totalBytesWritten, long long totalBytesExpectedToWrite))progress
    completeHandler:(dispatch_block_t)completeHandler{
    
    NSData *chunkData = [self getDataWithChunk:chunk block:block];
    if (chunkData == nil) {
        [self setErrorResponseInfo:[QNResponseInfo responseInfoWithLocalIOError:@"get chunk data error"] errorResponse:nil];
        completeHandler();
        return;
    }
    
    chunk.isUploading = YES;
    chunk.isCompleted = NO;
    
    kQNWeakSelf;
    QNRequestTransaction *transaction = [self createUploadRequestTransaction];
    [transaction uploadChunk:block.context
                 blockOffset:block.offset
                   chunkData:chunkData
                 chunkOffset:chunk.offset
                    progress:progress
                    complete:^(QNResponseInfo * _Nullable responseInfo, QNUploadRegionRequestMetrics * _Nullable metrics, NSDictionary * _Nullable response) {
        kQNStrongSelf;
        
        [self addRegionRequestMetricsOfOneFlow:metrics];
        
        NSString *blockContext = response[@"ctx"];
        if (responseInfo.isOK && blockContext) {
            block.context = blockContext;
            chunk.isUploading = NO;
            chunk.isCompleted = YES;
            [self recordUploadInfo];
            [self uploadRestChunk:completeHandler];
        } else {
            chunk.isUploading = NO;
            chunk.isCompleted = NO;
            [self setErrorResponseInfo:responseInfo errorResponse:response];
            completeHandler();
        }
    }];
}

- (void)makeFile:(void(^)(QNResponseInfo * _Nullable responseInfo, NSDictionary * _Nullable response))completeHandler {
    
    QNRequestTransaction *transaction = [self createUploadRequestTransaction];
    
    kQNWeakSelf;
    [transaction makeFile:self.uploadFileInfo.size
                 fileName:self.fileName
            blockContexts:[self.uploadFileInfo allBlocksContexts]
                 complete:^(QNResponseInfo * _Nullable responseInfo, QNUploadRegionRequestMetrics * _Nullable metrics, NSDictionary * _Nullable response) {
        kQNStrongSelf;
        
        [self addRegionRequestMetricsOfOneFlow:metrics];
        completeHandler(responseInfo, response);
    }];
}

- (void)setErrorResponseInfo:(QNResponseInfo *)responseInfo errorResponse:(NSDictionary *)response{
    if (!self.uploadChunkErrorResponseInfo
        || (responseInfo.statusCode == kQNNoUsableHostError)) {
        self.uploadChunkErrorResponseInfo = responseInfo;
        self.uploadChunkErrorResponse = response ?: responseInfo.responseDictionary;
    }
}

- (QNRequestTransaction *)createUploadRequestTransaction{
    QNRequestTransaction *transaction = [[QNRequestTransaction alloc] initWithConfig:self.config
                                                                        uploadOption:self.option
                                                                        targetRegion:[self getTargetRegion]
                                                                       currentRegion:[self getCurrentRegion]
                                                                                 key:self.key
                                                                               token:self.token];
    self.uploadTransaction = transaction;
    return transaction;
}

- (NSData *)getDataWithChunk:(QNUploadData *)chunk block:(QNUploadBlock *)block{
    if (!self.file) {
        return nil;
    }
    return [self.file read:(long)(chunk.offset + block.offset)
                      size:(long)chunk.size
                     error:nil];
}

@end
