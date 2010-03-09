-define(FILE_CACHE_TIME, 20000).

-record(media_info, {
  host,
  type = undefined,
  device = undefined,
  header = undefined,
  name = undefined,
  path = undefined,
  life_timeout = ?FILE_CACHE_TIME,
  life_timer = undefined,
  filter,
  format,
  width,
  height,
  duration,
  framerate,
  timescale,
  seconds,
  audio_codec = aac,
  video_codec = avc,
  video_decoder_config,
  audio_decoder_config,
  video_decoder,
  audio_track,
  video_track,
	frames = undefined,
	owner = undefined,
	clients = undefined,
	base_timestamp = undefined, % Timestamp of first frame
	last_dts,
	gop = []
}).
