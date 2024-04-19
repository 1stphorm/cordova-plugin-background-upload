#import "FileUploader.h"
@interface FileUploader()
@property (nonatomic, strong) NSMutableDictionary* responsesData;
@property (nonatomic, strong) AFURLSessionManager *manager;
@end

@implementation FileUploader

// Default values.
static NSInteger _parallelUploadsLimit = 5;
static NSInteger _resourceTimeout = 3600; // One hour.
static NSInteger _requestTimeout = 300; // 5 Minutes

static FileUploader *singletonObject = nil;
static NSString * kUploadUUIDStrPropertyKey = @"com.spoonconsulting.plugin-background-upload.UUID";

+(instancetype)sharedInstance{
    if (!singletonObject) {
        singletonObject = [[FileUploader alloc] init];
    }

    return singletonObject;
}

-(id)init{
    self = [super init];

    if (self == nil) {
        return nil;
    }

    // Ensure persistent storage is set up.
    [UploadEvent setupStorage];

    // Holding area for response data.
    self.responsesData = [[NSMutableDictionary alloc] init];

    NSURLSessionConfiguration* configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[[NSBundle mainBundle] bundleIdentifier]];

    configuration.timeoutIntervalForRequest = FileUploader.requestTimeout;
    configuration.timeoutIntervalForResource = FileUploader.resourceTimeout;
    configuration.HTTPMaximumConnectionsPerHost = FileUploader.parallelUploadsLimit;

    configuration.sessionSendsLaunchEvents = YES; // wake up the application when a task succeeds or fails

    __weak FileUploader *weakSelf = self;

    self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    [self.manager setTaskDidCompleteBlock:^(NSURLSession * _Nonnull session, NSURLSessionTask * _Nonnull task, NSError * _Nullable error) {
        // What is the ID of the upload?
        NSString* uploadId = [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:task.originalRequest];
        if (!error) {
            // If we did not get an error, then grab the response data (set down in the request handler) for this based on the uploadId.
            // This information will then go back to the application.
            NSLog(@"[BackgroundUpload] Task %@ completed successfully", uploadId);
            NSData* serverData = weakSelf.responsesData[@(task.taskIdentifier)];
            // Just a string. JSON conversion happens later.
            NSString* serverResponse = serverData ? [[NSString alloc] initWithData:serverData encoding:NSUTF8StringEncoding] : @"";
            // We're done with it. Remove it from storage. Move to persistence?
            [weakSelf.responsesData removeObjectForKey:@(task.taskIdentifier)];
            [weakSelf saveAndSendEvent:@{
                @"id": uploadId,
                @"state": @"UPLOADED",
                @"statusCode": @(((NSHTTPURLResponse *)task.response).statusCode),
                @"serverResponse": serverResponse
            }];
        } else {
            NSLog(@"[BackgroundUpload] Task %@ completed with error %@", uploadId, error);
            [weakSelf saveAndSendEvent:@{
                @"id": uploadId,
                @"state": @"FAILED",
                @"error": error.localizedDescription,
                @"errorCode": @(error.code)
            }];
        }
    }];

    // The individual tasks do not store their own data. We handle these, here at the manager level. When a response
    // is received, add or append the data to what is stored here in the responsesData dictionary.
    [self.manager setDataTaskDidReceiveDataBlock:^(NSURLSession * _Nonnull session, NSURLSessionDataTask * _Nonnull dataTask, NSData * _Nonnull data) {
        NSMutableData *responseData = weakSelf.responsesData[@(dataTask.taskIdentifier)];
        if (!responseData) {
            weakSelf.responsesData[@(dataTask.taskIdentifier)] = [NSMutableData dataWithData:data];
        } else {
            [responseData appendData:data];
        }
    }];

    return self;
}

-(void)saveAndSendEvent:(NSDictionary*)data{
    UploadEvent*event = [UploadEvent create:data];
    [self sendEvent:[event dataRepresentation]];
}

-(void)sendEvent:(NSDictionary*)info{
    [self.delegate uploadManagerDidReceiveCallback:info];
}


+(NSInteger)requestTimeout {
    return _requestTimeout;
}

+(void)setRequestTimeout:(NSInteger)value {
    _requestTimeout = value;
}

+(NSInteger)resourceTimeout {
    return _resourceTimeout;
}

+(void)setResourceTimeout:(NSInteger)value {
    _resourceTimeout = value;
}

+(NSInteger)parallelUploadsLimit {
    return _parallelUploadsLimit;
}

+(void)setParallelUploadsLimit:(NSInteger)value {
    _parallelUploadsLimit = value;
}

/**
 * Create and start an upload.
 */
-(void)addUpload:(NSDictionary *)payload
       completionHandler:(void (^)(NSError* error))handler {
    // If we have a fileKey, them assume it is a multi-part upload.
    if (payload[@"fileKey"] != nil) {
        [self addMultipartUpload:payload completionHandler:handler];
    } else {
        // Otherwise, just send the file.
        [self sendFile:payload completionHandler:handler];
    }
}

-(void)addMultipartUpload:(NSDictionary *)payload
        completionHandler:(void (^)(NSError* error))handler {
    __weak FileUploader *weakSelf = self;

    [self createRequestMultipartRequest: [NSURL URLWithString:payload[@"serverUrl"]]
                                method:[payload[@"requestMethod"] uppercaseString]
                              uploadId:payload[@"id"]
                               fileURL:[NSURL fileURLWithPath:payload[@"filePath"]]
                               headers: payload[@"headers"]
                            parameters:payload[@"parameters"]
                               fileKey:payload[@"fileKey"]
                     completionHandler:^(NSError *error, NSMutableURLRequest *request) {
        if (error)
            return handler(error);
        __block double lastProgressTimeStamp = 0;

        [[weakSelf.manager uploadTaskWithStreamedRequest:request
                                        progress:^(NSProgress * _Nonnull uploadProgress)
          {
            float roundedProgress = roundf(10 * (uploadProgress.fractionCompleted*100)) / 10.0;
            NSLog(@"[BackgroundUpload] Task %@ progression %f", [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:request], roundedProgress);
            NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
            if (currentTimestamp - lastProgressTimeStamp >= 1){
                lastProgressTimeStamp = currentTimestamp;
                [weakSelf sendEvent:@{
                    @"progress" : @(roundedProgress),
                    @"id" : [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:request],
                    @"state": @"UPLOADING"
                }];
            }
        }
                               completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
            if (error) {
                NSLog(@"Error: %@", error);
            } else {
                NSLog(@"%@ %@", response, responseObject);
            }
        }] resume];
    }];
}

-(void)sendFile:(NSDictionary *)payload
        completionHandler:(void (^)(NSError* error))handler {
    __weak FileUploader *weakSelf = self;

    [self createSingleFileRequest: [NSURL URLWithString:payload[@"serverUrl"]]
                                method:[payload[@"requestMethod"] uppercaseString]
                              uploadId:payload[@"id"]
                               headers: payload[@"headers"]
                     completionHandler:^(NSError *error, NSMutableURLRequest *request) {
        if (error)
            return handler(error);
        __block double lastProgressTimeStamp = 0;

        NSString *fileExtension = [[NSURL fileURLWithPath:payload[@"filePath"]] pathExtension];
        NSString *UTI = (__bridge_transfer NSString *)UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)fileExtension, NULL);
        NSString *contentType = (__bridge_transfer NSString *)UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)UTI, kUTTagClassMIMEType);

        // We must set this so that we get the correct Content-Type header.
        [request setValue:contentType forHTTPHeaderField:@"Content-Type"];

        [[weakSelf.manager uploadTaskWithRequest:request
                                        fromFile:[NSURL fileURLWithPath:payload[@"filePath"]]
                                        progress:^(NSProgress * _Nonnull uploadProgress)
          {
            float roundedProgress = roundf(10 * (uploadProgress.fractionCompleted*100)) / 10.0;
            NSLog(@"[BackgroundUpload] Task %@ progression %f", [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:request], roundedProgress);
            NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
            if (currentTimestamp - lastProgressTimeStamp >= 1){
                lastProgressTimeStamp = currentTimestamp;
                [weakSelf sendEvent:@{
                    @"progress" : @(roundedProgress),
                    @"id" : [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:request],
                    @"state": @"UPLOADING"
                }];
            }
        }
                               completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
            if (error) {
                NSLog(@"Error: %@", error);
            } else {
                NSLog(@"%@ %@", response, responseObject);
            }
        }] resume];
    }];
}


-(void)createRequestMultipartRequest: (NSURL*)url
                              method:(NSString*)method
                            uploadId:(NSString*)uploadId
                             fileURL:(NSURL *)fileURL
                             headers:(NSDictionary*)headers
                          parameters:(NSDictionary*)parameters
                             fileKey:(NSString*)fileKey
                   completionHandler:(void (^)(NSError* error, NSMutableURLRequest* request))handler{
    AFHTTPRequestSerializer *serializer = [AFHTTPRequestSerializer serializer];
    NSError *error;
    NSMutableURLRequest *request =
    [serializer multipartFormRequestWithMethod:method
                                     URLString:url.absoluteString
                                    parameters:parameters
                     constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
        [formData appendPartWithFileURL:fileURL name:fileKey error:nil];
    } error:&error];

    if (error)
        return handler(error, nil);
    for (NSString *key in headers) {
        [request setValue:[headers objectForKey:key] forHTTPHeaderField:key];
    }
    [NSURLProtocol setProperty:uploadId forKey:kUploadUUIDStrPropertyKey inRequest:request];

    handler(error, request);
}

-(void)createSingleFileRequest: (NSURL*)url
                        method:(NSString*)method
                      uploadId:(NSString*)uploadId
                       headers:(NSDictionary*)headers
            completionHandler:(void (^)(NSError* error, NSMutableURLRequest* request))handler{
    AFHTTPRequestSerializer *serializer = [AFHTTPRequestSerializer serializer];
    NSError *error;
    NSMutableURLRequest *request = [serializer requestWithMethod:method URLString:url.absoluteString parameters:nil error:&error];

    if (error)
        return handler(error, nil);
    for (NSString *key in headers) {
        [request setValue:[headers objectForKey:key] forHTTPHeaderField:key];
    }
    [NSURLProtocol setProperty:uploadId forKey:kUploadUUIDStrPropertyKey inRequest:request];

    handler(error, request);
}


-(void)removeUpload:(NSString*)uploadId{
    NSURLSessionUploadTask *correspondingTask =
    [[self.manager.uploadTasks filteredArrayUsingPredicate: [NSPredicate predicateWithBlock:^BOOL(NSURLSessionUploadTask* task, NSDictionary *bindings) {
        NSString* currentId = [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:task.originalRequest];
        return [uploadId isEqualToString:currentId];
    }]] firstObject];
    [correspondingTask cancel];
}

-(void)acknowledgeEventReceived:(NSString*)eventId{
    [[UploadEvent eventWithId:eventId] destroy];
}
@end
