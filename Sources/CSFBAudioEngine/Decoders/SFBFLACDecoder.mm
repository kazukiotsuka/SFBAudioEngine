//
// Copyright (c) 2006-2025 Stephen F. Booth <me@sbooth.org>
// Part of https://github.com/sbooth/SFBAudioEngine
// MIT license
//

#import <memory>

#import <os/log.h>

#import <FLAC/metadata.h>
#import <FLAC/stream_decoder.h>

#import <AVAudioPCMBuffer+SFBBufferUtilities.h>

#import "SFBFLACDecoder.h"

#import "NSData+SFBExtensions.h"
#import "NSError+SFBURLPresentation.h"

SFBAudioDecoderName const SFBAudioDecoderNameFLAC = @"org.sbooth.AudioEngine.Decoder.FLAC";
SFBAudioDecoderName const SFBAudioDecoderNameOggFLAC = @"org.sbooth.AudioEngine.Decoder.OggFLAC";

SFBAudioDecodingPropertiesKey const SFBAudioDecodingPropertiesKeyFLACMinimumBlockSize = @"min_blocksize";
SFBAudioDecodingPropertiesKey const SFBAudioDecodingPropertiesKeyFLACMaximumBlockSize = @"max_blocksize";
SFBAudioDecodingPropertiesKey const SFBAudioDecodingPropertiesKeyFLACMinimumFrameSize = @"min_framesize";
SFBAudioDecodingPropertiesKey const SFBAudioDecodingPropertiesKeyFLACMaximumFrameSize = @"max_framesize";
SFBAudioDecodingPropertiesKey const SFBAudioDecodingPropertiesKeyFLACSampleRate = @"sample_rate";
SFBAudioDecodingPropertiesKey const SFBAudioDecodingPropertiesKeyFLACChannels = @"channels";
SFBAudioDecodingPropertiesKey const SFBAudioDecodingPropertiesKeyFLACBitsPerSample = @"bits_per_sample";
SFBAudioDecodingPropertiesKey const SFBAudioDecodingPropertiesKeyFLACTotalSamples = @"total_samples";
SFBAudioDecodingPropertiesKey const SFBAudioDecodingPropertiesKeyFLACMD5Sum = @"md5sum";

namespace {

/// A `std::unique_ptr` deleter for `FLAC__StreamDecoder` objects
struct flac__stream_decoder_deleter {
	void operator()(FLAC__StreamDecoder *decoder) { FLAC__stream_decoder_delete(decoder); }
};

using flac__stream_decoder_unique_ptr = std::unique_ptr<FLAC__StreamDecoder, flac__stream_decoder_deleter>;

} /* namespace */

@interface SFBFLACDecoder ()
{
@private
	flac__stream_decoder_unique_ptr _flac;
	FLAC__StreamMetadata_StreamInfo _streamInfo;
	AVAudioFramePosition _framePosition;
	AVAudioPCMBuffer *_frameBuffer; // For converting push to pull
}
- (BOOL)initializeFLACStreamDecoder:(FLAC__StreamDecoder *)decoder error:(NSError **)error;
- (FLAC__StreamDecoderWriteStatus)handleFLACWrite:(const FLAC__StreamDecoder *)decoder frame:(const FLAC__Frame *)frame buffer:(const FLAC__int32 * const [])buffer;
- (void)handleFLACMetadata:(const FLAC__StreamDecoder *)decoder metadata:(const FLAC__StreamMetadata *)metadata;
- (void)handleFLACError:(const FLAC__StreamDecoder *)decoder status:(FLAC__StreamDecoderErrorStatus)status;
@end

#pragma mark FLAC Callbacks

namespace {

FLAC__StreamDecoderReadStatus read_callback(const FLAC__StreamDecoder *decoder, FLAC__byte buffer[], size_t *bytes, void *client_data) noexcept
{
#pragma unused(decoder)
	NSCParameterAssert(client_data != NULL);

	SFBFLACDecoder *flacDecoder = (__bridge SFBFLACDecoder *)client_data;
	SFBInputSource *inputSource = flacDecoder->_inputSource;

	NSInteger bytesRead;
	if(![inputSource readBytes:buffer length:static_cast<NSInteger>(*bytes) bytesRead:&bytesRead error:nil])
		return FLAC__STREAM_DECODER_READ_STATUS_ABORT;

	*bytes = static_cast<size_t>(bytesRead);

	if(bytesRead == 0 && inputSource.atEOF)
		return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;

	return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE;
}

FLAC__StreamDecoderSeekStatus seek_callback(const FLAC__StreamDecoder *decoder, FLAC__uint64 absolute_byte_offset, void *client_data) noexcept
{
#pragma unused(decoder)
	NSCParameterAssert(client_data != NULL);

	SFBFLACDecoder *flacDecoder = (__bridge SFBFLACDecoder *)client_data;
	SFBInputSource *inputSource = flacDecoder->_inputSource;

	if(!inputSource.supportsSeeking)
		return FLAC__STREAM_DECODER_SEEK_STATUS_UNSUPPORTED;

	if(![inputSource seekToOffset:static_cast<NSInteger>(absolute_byte_offset) error:nil])
		return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR;

	return FLAC__STREAM_DECODER_SEEK_STATUS_OK;
}

FLAC__StreamDecoderTellStatus tell_callback(const FLAC__StreamDecoder *decoder, FLAC__uint64 *absolute_byte_offset, void *client_data) noexcept
{
#pragma unused(decoder)
	NSCParameterAssert(client_data != NULL);

	SFBFLACDecoder *flacDecoder = (__bridge SFBFLACDecoder *)client_data;

	NSInteger offset;
	if(![flacDecoder->_inputSource getOffset:&offset error:nil])
		return FLAC__STREAM_DECODER_TELL_STATUS_ERROR;

	*absolute_byte_offset = static_cast<FLAC__uint64>(offset);
	return FLAC__STREAM_DECODER_TELL_STATUS_OK;
}

FLAC__StreamDecoderLengthStatus length_callback(const FLAC__StreamDecoder *decoder, FLAC__uint64 *stream_length, void *client_data) noexcept
{
#pragma unused(decoder)
	NSCParameterAssert(client_data != NULL);

	SFBFLACDecoder *flacDecoder = (__bridge SFBFLACDecoder *)client_data;

	NSInteger length;
	if(![flacDecoder->_inputSource getLength:&length error:nil])
		return FLAC__STREAM_DECODER_LENGTH_STATUS_ERROR;

	*stream_length = static_cast<FLAC__uint64>(length);
	return FLAC__STREAM_DECODER_LENGTH_STATUS_OK;
}

FLAC__bool eof_callback(const FLAC__StreamDecoder *decoder, void *client_data) noexcept
{
#pragma unused(decoder)
	NSCParameterAssert(client_data != NULL);

	SFBFLACDecoder *flacDecoder = (__bridge SFBFLACDecoder *)client_data;
	return flacDecoder->_inputSource.atEOF;
}

FLAC__StreamDecoderWriteStatus write_callback(const FLAC__StreamDecoder *decoder, const FLAC__Frame *frame, const FLAC__int32 * const buffer[], void *client_data) noexcept
{
#pragma unused(decoder)
	NSCParameterAssert(client_data != NULL);

	SFBFLACDecoder *flacDecoder = (__bridge SFBFLACDecoder *)client_data;
	return [flacDecoder handleFLACWrite:decoder frame:frame buffer:buffer];
}

void metadata_callback(const FLAC__StreamDecoder *decoder, const FLAC__StreamMetadata *metadata, void *client_data) noexcept
{
	NSCParameterAssert(client_data != NULL);

	SFBFLACDecoder *flacDecoder = (__bridge SFBFLACDecoder *)client_data;
	[flacDecoder handleFLACMetadata:decoder metadata:metadata];
}

void error_callback(const FLAC__StreamDecoder *decoder, FLAC__StreamDecoderErrorStatus status, void *client_data) noexcept
{
	NSCParameterAssert(client_data != NULL);

	SFBFLACDecoder *flacDecoder = (__bridge SFBFLACDecoder *)client_data;
	[flacDecoder handleFLACError:decoder status:status];
}

} /* namespace */

@implementation SFBFLACDecoder

+ (void)load
{
	[SFBAudioDecoder registerSubclass:[self class]];
}

+ (NSSet *)supportedPathExtensions
{
	return [NSSet setWithObject:@"flac"];
}

+ (NSSet *)supportedMIMETypes
{
	return [NSSet setWithObject:@"audio/flac"];
}

+ (SFBAudioDecoderName)decoderName
{
	return SFBAudioDecoderNameFLAC;
}

+ (BOOL)testInputSource:(SFBInputSource *)inputSource formatIsSupported:(SFBTernaryTruthValue *)formatIsSupported error:(NSError **)error
{
	NSParameterAssert(inputSource != nil);
	NSParameterAssert(formatIsSupported != NULL);

	NSData *header = [inputSource readHeaderOfLength:SFBFLACDetectionSize skipID3v2Tag:YES error:error];
	if(!header)
		return NO;

	if([header isFLACHeader])
		*formatIsSupported = SFBTernaryTruthValueTrue;
	else
		*formatIsSupported = SFBTernaryTruthValueFalse;

	return YES;
}

- (BOOL)decodingIsLossless
{
	return YES;
}

- (BOOL)openReturningError:(NSError **)error
{
	if(![super openReturningError:error])
		return NO;

	// Create FLAC decoder
	flac__stream_decoder_unique_ptr flac{FLAC__stream_decoder_new()};
	if(!flac) {
		if(error)
			*error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
		return NO;
	}

	// Initialize decoder
	if(![self initializeFLACStreamDecoder:flac.get() error:error])
		return NO;

	// Process metadata
	if(!FLAC__stream_decoder_process_until_end_of_metadata(flac.get())) {
		os_log_error(gSFBAudioDecoderLog, "FLAC__stream_decoder_process_until_end_of_metadata failed: %{public}s", FLAC__stream_decoder_get_resolved_state_string(flac.get()));

		if(error)
			*error = [NSError SFB_errorWithDomain:SFBAudioDecoderErrorDomain
											 code:SFBAudioDecoderErrorCodeInvalidFormat
					descriptionFormatStringForURL:NSLocalizedString(@"The file “%@” is not a valid FLAC file.", @"")
											  url:_inputSource.url
									failureReason:NSLocalizedString(@"Not a FLAC file", @"")
							   recoverySuggestion:NSLocalizedString(@"The file's extension may not match the file's type.", @"")];

		return NO;
	}

	// Set up the processing format
	AudioStreamBasicDescription processingStreamDescription{};

	processingStreamDescription.mFormatID			= kAudioFormatLinearPCM;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-anon-enum-enum-conversion"
	processingStreamDescription.mFormatFlags		= kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved;
#pragma clang diagnostic pop

	processingStreamDescription.mSampleRate			= _streamInfo.sample_rate;
	processingStreamDescription.mChannelsPerFrame	= _streamInfo.channels;
	processingStreamDescription.mBitsPerChannel		= _streamInfo.bits_per_sample;

	processingStreamDescription.mBytesPerPacket		= (_streamInfo.bits_per_sample + 7) / 8;
	processingStreamDescription.mFramesPerPacket	= 1;
	processingStreamDescription.mBytesPerFrame		= processingStreamDescription.mBytesPerPacket / processingStreamDescription.mFramesPerPacket;

	// FLAC supports from 4 to 32 bits per sample
	switch(processingStreamDescription.mBitsPerChannel) {
		case 8:
		case 16:
		case 24:
		case 32:
			processingStreamDescription.mFormatFlags |= kAudioFormatFlagIsPacked;
			break;

		case 4 ... 7:
		case 9 ... 15:
		case 17 ... 23:
		case 25 ... 31:
			// Align high because Apple's AudioConverter doesn't handle low alignment
			processingStreamDescription.mFormatFlags |= kAudioFormatFlagIsAlignedHigh;
			break;

		default: {
			os_log_error(gSFBAudioDecoderLog, "Unsupported bit depth: %u", _streamInfo.bits_per_sample);

			if(error)
				*error = [NSError SFB_errorWithDomain:SFBAudioDecoderErrorDomain
												 code:SFBAudioDecoderErrorCodeInvalidFormat
						descriptionFormatStringForURL:NSLocalizedString(@"The file “%@” is not a supported FLAC file.", @"")
												  url:_inputSource.url
										failureReason:NSLocalizedString(@"Bit depth not supported", @"")
								   recoverySuggestion:NSLocalizedString(@"The file's bit depth is not supported.", @"")];

			return NO;
		}
	}

	_flac = std::move(flac);

	AVAudioChannelLayout *channelLayout = nil;
	switch(_streamInfo.channels) {
		case 1:		channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_Mono];				break;
		case 2:		channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_Stereo];			break;
		case 3:		channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_MPEG_3_0_A];		break;
		case 4:		channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_WAVE_4_0_B];		break;
		case 5:		channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_WAVE_5_0_B];		break;
		case 6:		channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_WAVE_5_1_B];		break;
		case 7:		channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_WAVE_6_1];			break;
		case 8:		channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_WAVE_7_1];			break;
	}

	_processingFormat = [[AVAudioFormat alloc] initWithStreamDescription:&processingStreamDescription channelLayout:channelLayout];

	// Set up the source format
	AudioStreamBasicDescription sourceStreamDescription{};

	sourceStreamDescription.mFormatID			= kAudioFormatFLAC;

	sourceStreamDescription.mSampleRate			= _streamInfo.sample_rate;
	sourceStreamDescription.mChannelsPerFrame	= _streamInfo.channels;
	// Apple uses kAppleLosslessFormatFlag_XXBitSourceData to indicate FLAC bit depth in the Core Audio FLAC decoder
	// Since the number of flags is limited the source bit depth is also stored in mBitsPerChannel
	sourceStreamDescription.mBitsPerChannel		= _streamInfo.bits_per_sample;
	switch(_streamInfo.bits_per_sample) {
		case 16:
			sourceStreamDescription.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData;
			break;
		case 20:
			sourceStreamDescription.mFormatFlags = kAppleLosslessFormatFlag_20BitSourceData;
			break;
		case 24:
			sourceStreamDescription.mFormatFlags = kAppleLosslessFormatFlag_24BitSourceData;
			break;
		case 32:
			sourceStreamDescription.mFormatFlags = kAppleLosslessFormatFlag_32BitSourceData;
			break;
	}

	sourceStreamDescription.mFramesPerPacket	= _streamInfo.max_blocksize;

	_sourceFormat = [[AVAudioFormat alloc] initWithStreamDescription:&sourceStreamDescription channelLayout:channelLayout];

	// Populate codec properties
	_properties = @{
		SFBAudioDecodingPropertiesKeyFLACMinimumBlockSize: @(_streamInfo.min_blocksize),
		SFBAudioDecodingPropertiesKeyFLACMaximumBlockSize: @(_streamInfo.max_blocksize),
		SFBAudioDecodingPropertiesKeyFLACMinimumFrameSize: @(_streamInfo.min_framesize),
		SFBAudioDecodingPropertiesKeyFLACMaximumFrameSize: @(_streamInfo.max_framesize),
		SFBAudioDecodingPropertiesKeyFLACSampleRate: @(_streamInfo.sample_rate),
		SFBAudioDecodingPropertiesKeyFLACChannels: @(_streamInfo.channels),
		SFBAudioDecodingPropertiesKeyFLACBitsPerSample: @(_streamInfo.bits_per_sample),
		SFBAudioDecodingPropertiesKeyFLACTotalSamples: @(_streamInfo.total_samples),
		SFBAudioDecodingPropertiesKeyFLACMD5Sum: [[NSData alloc] initWithBytes:_streamInfo.md5sum length:16],
	};

	// Allocate the buffer list (which will convert from FLAC's push model to Core Audio's pull model)
	_frameBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_processingFormat frameCapacity:_streamInfo.max_blocksize];
	_frameBuffer.frameLength = 0;

	return YES;
}

- (BOOL)closeReturningError:(NSError **)error
{
	if(_flac && !FLAC__stream_decoder_finish(_flac.get()))
		os_log_info(gSFBAudioDecoderLog, "FLAC__stream_decoder_finish failed: %{public}s", FLAC__stream_decoder_get_resolved_state_string(_flac.get()));

	_flac.reset();

	_frameBuffer = nil;
	memset(&_streamInfo, 0, sizeof(_streamInfo));

	return [super closeReturningError:error];
}

- (BOOL)isOpen
{
	return _flac != NULL;
}

- (AVAudioFramePosition)framePosition
{
	return _framePosition;
}

- (AVAudioFramePosition)frameLength
{
	return static_cast<AVAudioFramePosition>(_streamInfo.total_samples);
}

- (BOOL)decodeIntoBuffer:(AVAudioPCMBuffer *)buffer frameLength:(AVAudioFrameCount)frameLength error:(NSError **)error
{
	NSParameterAssert(buffer != nil);
	NSParameterAssert([buffer.format isEqual:_processingFormat]);

	// Reset output buffer data size
	buffer.frameLength = 0;

	if(frameLength > buffer.frameCapacity)
		frameLength = buffer.frameCapacity;

	if(frameLength == 0)
		return YES;

	AVAudioFrameCount framesProcessed = 0;

	for(;;) {
		AVAudioFrameCount framesRemaining = frameLength - framesProcessed;
		AVAudioFrameCount framesCopied = [buffer appendFromBuffer:_frameBuffer readingFromOffset:0 frameLength:framesRemaining];
		[_frameBuffer trimAtOffset:0 frameLength:framesCopied];

		framesProcessed += framesCopied;

		// All requested frames were read or EOS reached
		if(framesProcessed == frameLength || FLAC__stream_decoder_get_state(_flac.get()) == FLAC__STREAM_DECODER_END_OF_STREAM)
			break;

		// Grab the next frame
		if(!FLAC__stream_decoder_process_single(_flac.get())) {
			os_log_error(gSFBAudioDecoderLog, "FLAC__stream_decoder_process_single failed: %{public}s", FLAC__stream_decoder_get_resolved_state_string(_flac.get()));
			if(error)
				*error = [NSError errorWithDomain:SFBAudioDecoderErrorDomain code:SFBAudioDecoderErrorCodeInternalError userInfo:@{ NSURLErrorKey: _inputSource.url }];
			return NO;
		}
	}

	_framePosition += framesProcessed;

	return YES;
}

- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error
{
	NSParameterAssert(frame >= 0);
//	NSParameterAssert(frame <= _totalFrames);

	FLAC__bool result = FLAC__stream_decoder_seek_absolute(_flac.get(), static_cast<FLAC__uint64>(frame));

	// Attempt to re-sync the stream if necessary
	if(FLAC__stream_decoder_get_state(_flac.get()) == FLAC__STREAM_DECODER_SEEK_ERROR)
		result = FLAC__stream_decoder_flush(_flac.get());

	if(result)
		_framePosition = frame;

	return result != 0;
}

- (BOOL)initializeFLACStreamDecoder:(FLAC__StreamDecoder *)decoder error:(NSError **)error
{
	auto status = FLAC__stream_decoder_init_stream(decoder, read_callback, seek_callback, tell_callback, length_callback, eof_callback, write_callback, metadata_callback, error_callback, (__bridge void *)self);
	if(status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
		os_log_error(gSFBAudioDecoderLog, "FLAC__stream_decoder_init_stream failed: %{public}s", FLAC__stream_decoder_get_resolved_state_string(decoder));

		if(error)
			*error = [NSError SFB_errorWithDomain:SFBAudioDecoderErrorDomain
											 code:SFBAudioDecoderErrorCodeInvalidFormat
					descriptionFormatStringForURL:NSLocalizedString(@"The file “%@” is not a valid FLAC file.", @"")
											  url:_inputSource.url
									failureReason:NSLocalizedString(@"Not a FLAC file", @"")
							   recoverySuggestion:NSLocalizedString(@"The file's extension may not match the file's type.", @"")];

		return NO;
	}

	return YES;
}

- (FLAC__StreamDecoderWriteStatus)handleFLACWrite:(const FLAC__StreamDecoder *)decoder frame:(const FLAC__Frame *)frame buffer:(const FLAC__int32 * const [])buffer
{
	NSParameterAssert(decoder != NULL);
	NSParameterAssert(frame != NULL);

	const AudioBufferList *abl = _frameBuffer.audioBufferList;
	if(abl->mNumberBuffers != frame->header.channels)
		return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;

	// FLAC hands us 32-bit signed integers with the samples low-aligned
	uint32_t bytesPerFrame = (frame->header.bits_per_sample + 7) / 8;
	if(bytesPerFrame != _frameBuffer.format.streamDescription->mBytesPerFrame)
		return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;

	switch(bytesPerFrame) {
		case 1: {
			for(uint32_t channel = 0; channel < frame->header.channels; ++channel) {
				int8_t *dst = static_cast<int8_t *>(abl->mBuffers[channel].mData);
				for(uint32_t sample = 0; sample < frame->header.blocksize; ++sample)
					*dst++ = static_cast<int8_t>(buffer[channel][sample]);
			}

			_frameBuffer.frameLength = frame->header.blocksize;
			break;
		}

		case 2: {
			for(uint32_t channel = 0; channel < frame->header.channels; ++channel) {
				int16_t *dst = static_cast<int16_t *>(abl->mBuffers[channel].mData);
				for(uint32_t sample = 0; sample < frame->header.blocksize; ++sample)
					*dst++ = static_cast<int16_t>(buffer[channel][sample]);
			}

			_frameBuffer.frameLength = frame->header.blocksize;
			break;
		}

		case 3: {
			for(uint32_t channel = 0; channel < frame->header.channels; ++channel) {
				uint8_t *dst = static_cast<uint8_t *>(abl->mBuffers[channel].mData);
				for(uint32_t sample = 0; sample < frame->header.blocksize; ++sample) {
					uint32_t value = OSSwapHostToLittleInt32(buffer[channel][sample]);
					*dst++ = static_cast<uint8_t>(value & 0xff);
					*dst++ = static_cast<uint8_t>((value >> 8) & 0xff);
					*dst++ = static_cast<uint8_t>((value >> 16) & 0xff);
				}
			}

			_frameBuffer.frameLength = frame->header.blocksize;
			break;
		}

		case 4: {
			for(uint32_t channel = 0; channel < frame->header.channels; ++channel) {
				int32_t *dst = static_cast<int32_t *>(abl->mBuffers[channel].mData);
				for(uint32_t sample = 0; sample < frame->header.blocksize; ++sample)
					*dst++ = static_cast<int32_t>(buffer[channel][sample]);
			}

			_frameBuffer.frameLength = frame->header.blocksize;
			break;
		}
	}

	return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

- (void)handleFLACMetadata:(const FLAC__StreamDecoder *)decoder metadata:(const FLAC__StreamMetadata *)metadata
{
	NSParameterAssert(metadata != NULL);

	if(metadata->type == FLAC__METADATA_TYPE_STREAMINFO)
		memcpy(&_streamInfo, &metadata->data.stream_info, sizeof(metadata->data.stream_info));
}

- (void)handleFLACError:(const FLAC__StreamDecoder *)decoder status:(FLAC__StreamDecoderErrorStatus)status
{
	os_log_error(gSFBAudioDecoderLog, "FLAC error: %{public}s", FLAC__StreamDecoderErrorStatusString[status]);
}

@end

@implementation SFBOggFLACDecoder

+ (void)load
{
	[SFBAudioDecoder registerSubclass:[self class]];
}

+ (NSSet *)supportedPathExtensions
{
	return [NSSet setWithObject:@"oga"];
}

+ (NSSet *)supportedMIMETypes
{
	return [NSSet setWithObject:@"audio/ogg; codecs=flac"];
}

+ (SFBAudioDecoderName)decoderName
{
	return SFBAudioDecoderNameOggFLAC;
}

+ (BOOL)testInputSource:(SFBInputSource *)inputSource formatIsSupported:(SFBTernaryTruthValue *)formatIsSupported error:(NSError **)error
{
	NSParameterAssert(inputSource != nil);
	NSParameterAssert(formatIsSupported != NULL);

	NSData *header = [inputSource readHeaderOfLength:SFBOggFLACDetectionSize skipID3v2Tag:NO error:error];
	if(!header)
		return NO;

	if([header isOggFLACHeader])
		*formatIsSupported = SFBTernaryTruthValueTrue;
	else
		*formatIsSupported = SFBTernaryTruthValueFalse;

	return YES;
}

- (BOOL)initializeFLACStreamDecoder:(FLAC__StreamDecoder *)decoder error:(NSError **)error
{

	auto status = FLAC__stream_decoder_init_ogg_stream(decoder, read_callback, seek_callback, tell_callback, length_callback, eof_callback, write_callback, metadata_callback, error_callback, (__bridge void *)self);

	if(status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
		os_log_error(gSFBAudioDecoderLog, "FLAC__stream_decoder_init_ogg_stream failed: %{public}s", FLAC__stream_decoder_get_resolved_state_string(decoder));

		if(error)
			*error = [NSError SFB_errorWithDomain:SFBAudioDecoderErrorDomain
											 code:SFBAudioDecoderErrorCodeInvalidFormat
					descriptionFormatStringForURL:NSLocalizedString(@"The file “%@” is not a valid Ogg FLAC file.", @"")
											  url:_inputSource.url
									failureReason:NSLocalizedString(@"Not an Ogg FLAC file", @"")
							   recoverySuggestion:NSLocalizedString(@"The file's extension may not match the file's type.", @"")];

		return NO;
	}

	return YES;
}

@end
