//
// Copyright (c) 2006-2025 Stephen F. Booth <me@sbooth.org>
// Part of https://github.com/sbooth/SFBAudioEngine
// MIT license
//

#import <taglib/tfilestream.h>
#import <taglib/vorbisfile.h>

#import "SFBOggVorbisFile.h"

#import "AddAudioPropertiesToDictionary.h"
#import "NSData+SFBExtensions.h"
#import "NSError+SFBURLPresentation.h"
#import "NSFileHandle+SFBHeaderReading.h"
#import "SFBAudioMetadata+TagLibXiphComment.h"

SFBAudioFileFormatName const SFBAudioFileFormatNameOggVorbis = @"org.sbooth.AudioEngine.File.OggVorbis";

@implementation SFBOggVorbisFile

+ (void)load
{
	[SFBAudioFile registerSubclass:[self class]];
}

+ (NSSet *)supportedPathExtensions
{
	return [NSSet setWithArray:@[@"ogg", @"oga"]];
}

+ (NSSet *)supportedMIMETypes
{
	return [NSSet setWithObject:@"audio/ogg; codecs=vorbis"];
}

+ (SFBAudioFileFormatName)formatName
{
	return SFBAudioFileFormatNameOggVorbis;
}

+ (BOOL)testFileHandle:(NSFileHandle *)fileHandle formatIsSupported:(SFBTernaryTruthValue *)formatIsSupported error:(NSError **)error
{
	NSParameterAssert(fileHandle != nil);
	NSParameterAssert(formatIsSupported != NULL);

	NSData *header = [fileHandle readHeaderOfLength:SFBOggVorbisDetectionSize skipID3v2Tag:NO error:error];
	if(!header)
		return NO;

	if([header isOggVorbisHeader])
		*formatIsSupported = SFBTernaryTruthValueTrue;
	else
		*formatIsSupported = SFBTernaryTruthValueFalse;

	return YES;
}

- (BOOL)readPropertiesAndMetadataReturningError:(NSError **)error
{
	try {
		TagLib::FileStream stream(self.url.fileSystemRepresentation, true);
		if(!stream.isOpen()) {
			if(error)
				*error = [NSError SFB_errorWithDomain:SFBAudioFileErrorDomain
												 code:SFBAudioFileErrorCodeInputOutput
						descriptionFormatStringForURL:NSLocalizedString(@"The file “%@” could not be opened for reading.", @"")
												  url:self.url
										failureReason:NSLocalizedString(@"Input/output error", @"")
								   recoverySuggestion:NSLocalizedString(@"The file may have been renamed, moved, deleted, or you may not have appropriate permissions.", @"")];
			return NO;
		}

		TagLib::Ogg::Vorbis::File file(&stream);
		if(!file.isValid()) {
			if(error)
				*error = [NSError SFB_errorWithDomain:SFBAudioFileErrorDomain
												 code:SFBAudioFileErrorCodeInvalidFormat
						descriptionFormatStringForURL:NSLocalizedString(@"The file “%@” is not a valid Ogg Vorbis file.", @"")
												  url:self.url
										failureReason:NSLocalizedString(@"Not an Ogg Vorbis file", @"")
								   recoverySuggestion:NSLocalizedString(@"The file's extension may not match the file's type.", @"")];
			return NO;
		}

		NSMutableDictionary *propertiesDictionary = [NSMutableDictionary dictionaryWithObject:@"Ogg Vorbis" forKey:SFBAudioPropertiesKeyFormatName];
		if(file.audioProperties())
			SFB::Audio::AddAudioPropertiesToDictionary(file.audioProperties(), propertiesDictionary);

		SFBAudioMetadata *metadata = [[SFBAudioMetadata alloc] init];
		if(file.tag())
			[metadata addMetadataFromTagLibXiphComment:file.tag()];

		self.properties = [[SFBAudioProperties alloc] initWithDictionaryRepresentation:propertiesDictionary];
		self.metadata = metadata;

		return YES;
	}
	catch(const std::exception& e) {
		os_log_error(gSFBAudioFileLog, "Error reading Ogg Vorbis properties and metadata: %{public}s", e.what());
		if(error)
			*error = [NSError errorWithDomain:SFBAudioFileErrorDomain code:SFBAudioFileErrorCodeInternalError userInfo:nil];
		return NO;
	}
}

- (BOOL)writeMetadataReturningError:(NSError **)error
{
	try {
		TagLib::FileStream stream(self.url.fileSystemRepresentation);
		if(!stream.isOpen()) {
			if(error)
				*error = [NSError SFB_errorWithDomain:SFBAudioFileErrorDomain
												 code:SFBAudioFileErrorCodeInputOutput
						descriptionFormatStringForURL:NSLocalizedString(@"The file “%@” could not be opened for writing.", @"")
												  url:self.url
										failureReason:NSLocalizedString(@"Input/output error", @"")
								   recoverySuggestion:NSLocalizedString(@"The file may have been renamed, moved, deleted, or you may not have appropriate permissions.", @"")];
			return NO;
		}

		TagLib::Ogg::Vorbis::File file(&stream, false);
		if(!file.isValid()) {
			if(error)
				*error = [NSError SFB_errorWithDomain:SFBAudioFileErrorDomain
												 code:SFBAudioFileErrorCodeInvalidFormat
						descriptionFormatStringForURL:NSLocalizedString(@"The file “%@” is not a valid Ogg Vorbis file.", @"")
												  url:self.url
										failureReason:NSLocalizedString(@"Not an Ogg Vorbis file", @"")
								   recoverySuggestion:NSLocalizedString(@"The file's extension may not match the file's type.", @"")];
			return NO;
		}

		SFB::Audio::SetXiphCommentFromMetadata(self.metadata, file.tag());

		if(!file.save()) {
			if(error)
				*error = [NSError SFB_errorWithDomain:SFBAudioFileErrorDomain
												 code:SFBAudioFileErrorCodeInputOutput
						descriptionFormatStringForURL:NSLocalizedString(@"The file “%@” could not be saved.", @"")
												  url:self.url
										failureReason:NSLocalizedString(@"Unable to write metadata", @"")
								   recoverySuggestion:NSLocalizedString(@"The file's extension may not match the file's type.", @"")];
			return NO;
		}

		return YES;
	}
	catch(const std::exception& e) {
		os_log_error(gSFBAudioFileLog, "Error writing Ogg Vorbis metadata: %{public}s", e.what());
		if(error)
			*error = [NSError errorWithDomain:SFBAudioFileErrorDomain code:SFBAudioFileErrorCodeInternalError userInfo:nil];
		return NO;
	}
}

@end
