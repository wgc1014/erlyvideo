%%% @author     Max Lapshin <max@maxidoors.ru>
%%% @author     Takuma Mori <mori@sgra.co.jp> [http://www.sgra.co.jp/en/], SGRA Corporation
%%% @copyright  2008 Takuma Mori, 2009 Max Lapshin
%%% @doc        MP4 decoding module, rewritten from RubyIzumi
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org/</a> for more information
%%% @end
%%%
%%%
%%% Copyright (c) 2009 Max Lapshin
%%%    This program is free software: you can redistribute it and/or modify
%%%    it under the terms of the GNU Affero General Public License as
%%%    published by the Free Software Foundation, either version 3 of the
%%%    License, or any later version.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%%---------------------------------------------------------------------------------------

-module(mp4).
-author('Max Lapshin <max@maxidoors.ru>').
-include("../../include/ems.hrl").
-include("../../include/mp4.hrl").
-include_lib("erlyvideo/include/video_frame.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("erlyvideo/include/media_info.hrl").

-export([init/1, read_frame/2, metadata/1, codec_config/2, seek/2, first/1]).
-export([ftyp/2, moov/2, mvhd/2, trak/2, tkhd/2, mdia/2, mdhd/2, stbl/2, stsd/2, esds/2, avcC/2,
btrt/2, stsz/2, stts/2, stsc/2, stss/2, stco/2, smhd/2, minf/2, ctts/2]).


-export([mp4_desc_length/1]).

-behaviour(gen_format).

codec_config(video, #media_info{video_codec = VideoCodec} = MediaInfo) ->
  Config = decoder_config(video, MediaInfo),
  % ?D({"Video config", Config}),
  #video_frame{       
   	type          = video,
   	decoder_config = true,
		dts           = 0,
		pts           = 0,
		body          = Config,
		frame_type    = keyframe,
		codec_id      = VideoCodec
	};

codec_config(audio, #media_info{audio_codec = AudioCodec} = MediaInfo) ->
  Config = decoder_config(audio, MediaInfo),
  % ?D({"Audio config", aac:decode_config(Config)}),
  #video_frame{       
   	type          = audio,
   	decoder_config = true,
		dts           = 0,
		pts           = 0,
		body          = Config,
	  codec_id	= AudioCodec,
	  sound_type	  = stereo,
	  sound_size	  = bit16,
	  sound_rate	  = rate44
	}.


first(#media_info{video_track = Video}) ->
  {video, ets:first(Video)}.


lookup_frame(video, #media_info{video_track = FrameTable}, Id) ->
  [Frame] = ets:lookup(FrameTable, Id),
  Frame;

lookup_frame(audio, #media_info{audio_track = FrameTable}, Id) ->
  [Frame] = ets:lookup(FrameTable, Id),
  Frame.

next_frame(#media_info{video_track = Video, audio_track = Audio}, DTS) ->
  MatchSpec = ets:fun2ms(fun(#mp4_frame{id = ID, dts = TS}) when TS > DTS ->
    {ID, TS}
  end),
  {[NextVideo], _} = ets:select(Video, MatchSpec, 1),
  {[NextAudio], _} = ets:select(Audio, MatchSpec, 1),
  case {NextVideo, NextAudio} of
    {'$end_of_table', '$end_of_table'} -> '$end_of_table';
    {'$end_of_table', {NextAudioID, _}} -> {audio, NextAudioID};
    {{NextVideoID, _}, '$end_of_table'} -> {video, NextVideoID};
    {{NextVideoID, NextVideoDTS}, {_, NextAudioDTS}} when NextVideoDTS < NextAudioDTS -> {video, NextVideoID};
    {_, {NextAudioID, _}} -> {audio, NextAudioID}
  end.

read_frame(#media_info{} = MediaInfo, {Type, Id}) ->
  Frame = lookup_frame(Type, MediaInfo, Id),
  #mp4_frame{offset = Offset, size = Size, dts = DTS} = Frame,
  Next = next_frame(MediaInfo, DTS),
  
  % F1 = video_frame(Type, Frame, <<>>),
  % ?D({Type, Id, F1#video_frame.dts, Next}),
  
	case read_data(MediaInfo, Offset, Size) of
		{ok, Data, _} -> {video_frame(Type, Frame, Data), Next};
    eof -> done;
    {error, Reason} -> {error, Reason}
  end.
  

read_data(#media_info{device = IoDev} = MediaInfo, Offset, Size) ->
  case file:pread(IoDev, Offset, Size) of
    {ok, Data} ->
      {ok, Data, MediaInfo};
    Else -> Else
  end.
  
seek(FrameTable, Timestamp) ->
  Ids = ets:select(FrameTable, ets:fun2ms(fun(#mp4_frame{id = Id, dts = FrameTimestamp, keyframe = true} = _Frame) when FrameTimestamp =< Timestamp ->
    {Id, FrameTimestamp}
  end)),
  case lists:reverse(Ids) of
    [Item | _] -> Item;
    _ -> undefined
  end.
  

video_frame(video, #mp4_frame{dts = DTS, keyframe = Keyframe, composition = CTime}, Data) ->
  #video_frame{
   	type          = video,
		dts           = DTS,
		pts           = DTS + CTime,
		body          = Data,
		frame_type    = case Keyframe of
		  true ->	keyframe;
		  _ -> frame
	  end,
		codec_id      = avc
  };  

video_frame(audio, #mp4_frame{dts = DTS}, Data) ->
  #video_frame{       
   	type          = audio,
		dts           = DTS,
		pts           = DTS,
  	body          = Data,
	  codec_id	    = aac,
	  sound_type	  = stereo,
	  sound_size	  = bit16,
	  sound_rate	  = rate44
  }.



init(#media_info{header = undefined} = MediaInfo) -> 
  Info1 = MediaInfo#media_info{header = #mp4_header{}, frames = ets:new(frames, [ordered_set, {keypos, #file_frame.id}])},
  % eprof:start(),
  % eprof:start_profiling([self()]),
  {Time, Result} = timer:tc(?MODULE, init, [Info1]),
  ?D({"Time to parse moov", round(Time/1000)}),
  % eprof:total_analyse(),
  % eprof:stop(),
  Result;

init(MediaInfo) -> 
  init(MediaInfo, 0).

init(MediaInfo, Pos) -> 
  case next_atom(#media_info{device = Device} = MediaInfo, Pos) of
    eof -> {ok, MediaInfo};
    {error, Reason} -> {error, Reason};
    {atom, mdat, Offset, Length} ->
      init(MediaInfo, Offset + Length);
    {atom, _AtomName, Offset, 0} -> 
      init(MediaInfo, Offset);
    {atom, AtomName, Offset, Length} -> 
      ?D({"Root atom", AtomName, Length}),
      {ok, AtomData} = file:pread(Device, Offset, Length),
      NewInfo = case ems:respond_to(?MODULE, AtomName, 2) of
        true -> ?MODULE:AtomName(AtomData, MediaInfo);
        false -> ?D({"Unknown atom", AtomName}), MediaInfo
      end,
      init(NewInfo, Offset + Length)
  end.

next_atom(#media_info{device = Device}, Pos) ->
  case file:pread(Device, Pos, 8) of
    {ok, <<AtomLength:32, AtomName/binary>>} when AtomLength >= 8 ->
      % ?D({"Atom", binary_to_atom(AtomName, latin1), Pos, AtomLength}),
      {atom, binary_to_atom(AtomName, utf8), Pos + 8, AtomLength - 8};
    Else -> Else
  end.


  
metadata(#media_info{width = Width, height = Height, seconds = Duration}) -> 
  [{width, Width}, 
   {height, Height}, 
   {duration, Duration}].
  
  
decoder_config(video, #media_info{video_decoder_config = DecoderConfig}) -> DecoderConfig;
decoder_config(audio, #media_info{audio_decoder_config = DecoderConfig}) -> DecoderConfig.



  
parse_atom(<<>>, Mp4Parser) ->
  Mp4Parser;
  
parse_atom(Atom, _) when size(Atom) < 4 ->
  {error, "Invalid atom"};
  
parse_atom(<<AllAtomLength:32, BinaryAtomName:4/binary, AtomRest/binary>>, Mp4Parser) when (size(AtomRest) >= AllAtomLength - 8) ->
  AtomLength = AllAtomLength - 8,
  <<Atom:AtomLength/binary, Rest/binary>> = AtomRest,
  AtomName = binary_to_atom(BinaryAtomName, utf8),
  NewMp4Parser = case ems:respond_to(?MODULE, AtomName, 2) of
    true -> ?MODULE:AtomName(Atom, Mp4Parser);
    false -> ?D({"Unknown atom", AtomName}), Mp4Parser
  end,
  parse_atom(Rest, NewMp4Parser);
  
parse_atom(<<AllAtomLength:32, BinaryAtomName:4/binary, _Rest/binary>>, Mp4Parser) ->
  ?D({"Invalid atom", AllAtomLength, binary_to_atom(BinaryAtomName, utf8), size(_Rest)}),
  Mp4Parser;

parse_atom(<<0:32>>, Mp4Parser) ->
  ?D("NULL atom"),
  Mp4Parser.

  
% FTYP atom
ftyp(<<_Major:4/binary, _Minor:4/binary, _CompatibleBrands/binary>>, MediaInfo) ->
  ?D({"File", _Major, _Minor, ftyp(_CompatibleBrands, [])}),
  % NewParser = Mp4Parser#mp4_header{file_type = binary_to_list(Major), file_types = decode_atom(ftyp, CompatibleBrands, [])},
  MediaInfo;

ftyp(<<>>, BrandList) when is_list(BrandList) ->
  lists:reverse(BrandList);

ftyp(<<Brand:4/binary, CompatibleBrands/binary>>, BrandList) ->
  ftyp(CompatibleBrands, [Brand|BrandList]).
  
% Movie box
moov(Atom, MediaInfo) ->
  parse_atom(Atom, MediaInfo).

% MVHD atom
mvhd(<<0:8, _Flags:3/binary, _CTime:32, _MTime:32, TimeScale:32,
                    Duration:32, _Rest/binary>>, #media_info{} = MediaInfo) ->
  MediaInfo#media_info{timescale = TimeScale, duration = Duration, seconds = Duration/TimeScale}.

% Track box
trak(<<>>, MediaInfo) ->
  MediaInfo;
  
trak(Atom, #media_info{} = MediaInfo) ->
  Track = parse_atom(Atom, #mp4_track{frames = ets:new(frames, [ordered_set, {keypos, #mp4_frame.id}])}),
  fill_track_info(MediaInfo, Track).
  

% Track header
tkhd(<<0:8, _Flags:3/binary, _CTime:32, _MTime:32,
                    TrackID:32, _Reserved1:4/binary, 
                    Duration:32, _Reserved2:8/binary,
                    _Layer:16, _AlternateGroup:2/binary,
                    _Volume:2/binary, _Reserved3:2/binary,
                    _Matrix:36/binary, _TrackWidth:4/binary, _TrackHeigth:4/binary>>, Mp4Track) ->
  Mp4Track#mp4_track{track_id = TrackID, duration = Duration}.

% Media box
mdia(Atom, Mp4Track) ->
  parse_atom(Atom, Mp4Track).

% Media header
mdhd(<<0:8, _Flags:24, _Ctime:32, 
                  _Mtime:32, TimeScale:32, Duration:32,
                  _Language:2/binary, _Quality:16>>, #mp4_track{} = Mp4Track) ->
  % ?D({"Timescale:", Duration, extract_language(_Language)}),
  _DecodedLanguate = extract_language(_Language),
  Mp4Track#mp4_track{timescale = TimeScale, duration = Duration};

mdhd(<<1:8, _Flags:24, _Ctime:64, 
                     _Mtime:64, TimeScale:32, Duration:64, 
                     _Language:2/binary, _Quality:16>>, Mp4Track) ->
  % ?D({"Timescale:", Duration, extract_language(_Language)}),
  Mp4Track#mp4_track{timescale = TimeScale, duration = Duration}.
  
% SMHD atom
smhd(<<0:8, _Flags:3/binary, 0:16/big-signed-integer, _Reserve:2/binary>>, Mp4Track) ->
  Mp4Track;

smhd(<<0:8, _Flags:3/binary, _Balance:16/big-signed-integer, _Reserve:2/binary>>, Mp4Track) ->
  Mp4Track.

% Media information
minf(Atom, Mp4Track) ->
  parse_atom(Atom, Mp4Track).

% Sample table box
stbl(Atom, Mp4Track) ->
  parse_atom(Atom, Mp4Track).

% Sample description
stsd(<<0:8, _Flags:3/binary, EntryCount:32, EntryData/binary>>, Mp4Track) ->
  stsd({EntryCount, EntryData}, Mp4Track);

stsd({0, _}, Mp4Track) ->
  Mp4Track;

stsd({_, <<>>}, Mp4Track) ->
  Mp4Track;
  
stsd({_EntryCount, <<_SampleDescriptionSize:32, 
                                  "mp4a", _Reserved:6/binary, _RefIndex:16, 
                                  _Unknown:8/binary, _ChannelsCount:32,
                                  _SampleSize:32, _SampleRate:32,
                                  Atom/binary>>}, Mp4Track) ->
  parse_atom(Atom, Mp4Track#mp4_track{data_format = mp4a});

stsd({_EntryCount, <<_SampleDescriptionSize:32, 
                                  "avc1", _Reserved:6/binary, _RefIndex:16, 
                                  _Unknown1:16/binary, 
                                  Width:16, Height:16,
                                  _HorizRes:32, _VertRes:32,
                                  _FrameCount:16, _CompressorName:32/binary,
                                  _Depth:16, _Predefined:16,
                                  _Unknown:4/binary,
                                  Atom/binary>>}, Mp4Track) ->
  % ?D({"Video size:", Width, Height}),
  parse_atom(Atom, Mp4Track#mp4_track{data_format = avc1, width = Width, height = Height});

stsd({_EntryCount, <<_SampleDescriptionSize:32, 
                                  "s263", _Reserved:6/binary, _RefIndex:16, 
                                  _Unknown1:16/binary, 
                                  Width:16, Height:16,
                                  _HorizRes:32, _VertRes:32,
                                  _FrameCount:16, _CompressorName:32/binary,
                                  _Depth:16, _Predefined:16,
                                  _Unknown:4/binary,
                                  Atom/binary>>}, Mp4Track) ->
  % ?D({"Video size:", Width, Height}),
  parse_atom(Atom, Mp4Track#mp4_track{data_format = s263, width = Width, height = Height});

stsd({_EntryCount,   <<_SampleDescriptionSize:32, 
                                    "samr", _Reserved:2/binary, _RefIndex:16, 
                                    Atom/binary>> = AMR}, Mp4Track) ->
  ?D(AMR),
  parse_atom(Atom, Mp4Track#mp4_track{data_format = samr});



stsd({_EntryCount, <<SampleDescriptionSize:32, DataFormat:4/binary, 
                                 _Reserved:6/binary, _RefIndex:16, EntryData/binary>>}, Mp4Track) 
           when SampleDescriptionSize == size(EntryData) + 16 ->
  NewTrack = Mp4Track#mp4_track{data_format = binary_to_atom(DataFormat, utf8)},
  ?D({"Unknown sample description:", NewTrack#mp4_track.data_format, SampleDescriptionSize, size(EntryData), binary_to_list(EntryData)}),
  NewTrack.
  
% ESDS atom
esds(<<Version:8, _Flags:3/binary, DecoderConfig/binary>>, #mp4_track{data_format = mp4a} = Mp4Track) when Version == 0 ->
  ?D({"Extracted audio config", DecoderConfig}),
  Mp4Track#mp4_track{decoder_config = config_from_esds_tag(DecoderConfig)}.

% avcC atom
avcC(DecoderConfig, #mp4_track{} = Mp4Track) ->
  % ?D({"Extracted video config"}),
  Mp4Track#mp4_track{decoder_config = DecoderConfig}.

btrt(<<_BufferSize:32, _MaxBitRate:32, _AvgBitRate:32>>, #mp4_track{} = Mp4Track) ->
  Mp4Track.


set_frame(Frames, Id, Pos, Value) ->
  case ets:update_element(Frames, Id, {Pos, Value}) of
    true -> 
      ok;
    false ->
      Frame = #mp4_frame{id = Id},
      ets:insert(Frames, setelement(Pos, Frame, Value)),
      ok
  end.

set_frames(_, _, _, _, 0) ->
  ok;

set_frames(Frames, Id, Pos, Value, Count) ->
  set_frame(Frames, Id, Pos, Value),
  set_frames(Frames, Id + 1, Pos, Value, Count - 1).

% STSZ atom

stsz(<<_Version:8, _Flags:24, 0:32, SampleCount:32, SampleSizeData/binary>>, #mp4_track{frames = Frames} = Mp4Track) ->
  read_stsz(SampleSizeData, SampleCount, Frames, 0),
  Mp4Track.
  
read_stsz(_, 0, _, _) ->
  ok;
read_stsz(<<Size:32, Rest/binary>>, Count, Frames, Id) ->
  set_frame(Frames, Id, #mp4_frame.size, Size),
  read_stsz(Rest, Count - 1, Frames, Id + 1).


  

% STTS atom
stts(<<0:8, _Flags:3/binary, EntryCount:32, Rest/binary>>, #mp4_track{frames = Frames, timescale = Timescale} = Mp4Track) ->
  read_stts(Rest, EntryCount, Frames, 0, 0, Timescale),
  Mp4Track.

read_stts(_, 0, _Frames, _, _, _) ->
  ok;
  
read_stts(<<SampleCount:32, SampleDuration:32, Rest/binary>>, EntryCount, Frames, Id, Timestamp, Timescale) ->
  NewTS = set_stts(SampleCount, SampleDuration, Timestamp, Frames, Id, Timescale),
  read_stts(Rest, EntryCount - 1, Frames, Id + SampleCount, NewTS, Timescale).

set_stts(0, _Duration, Timestamp, _Frames, _Id, _Timescale) ->
  Timestamp;
  
set_stts(SampleCount, Duration, Timestamp, Frames, Id, Timescale) ->
  set_frame(Frames, Id, #mp4_frame.dts, Timestamp*1000/Timescale),
  set_stts(SampleCount - 1, Duration, Timestamp + Duration, Frames, Id + 1, Timescale).
  
% STSC atom
stsc(<<0:8, _Flags:3/binary, EntryCount:32, Rest/binary>>, #mp4_track{frames = Frames} = Mp4Track) ->
  read_stsc(Rest, EntryCount, Frames, 0),
  Mp4Track.



set_chunk_id(ChunkId, _SamplesPerChunk, ChunkId, _Frames, Id) ->
  Id;

set_chunk_id(ChunkId, SamplesPerChunk, undefined, Frames, Id) ->
  set_frames(Frames, Id, #mp4_frame.chunk_id, ChunkId - 1, SamplesPerChunk),
  case ets:last(Frames) of
    MaxId when MaxId =< Id + SamplesPerChunk -> ok;
    _ -> set_chunk_id(ChunkId + 1, SamplesPerChunk, undefined, Frames, Id + SamplesPerChunk)
  end;

set_chunk_id(ChunkId, SamplesPerChunk, NextChunk, Frames, Id) ->
  set_frames(Frames, Id, #mp4_frame.chunk_id, ChunkId - 1, SamplesPerChunk),
  set_chunk_id(ChunkId + 1, SamplesPerChunk, NextChunk, Frames, Id + SamplesPerChunk).
  
read_stsc(_, 0, _Frames, _) ->
  ok;

read_stsc(<<ChunkId:32, SamplesPerChunk:32, _SampleId:32>>, 1, Frames, Id) ->
  set_chunk_id(ChunkId, SamplesPerChunk, undefined, Frames, Id),
  ok;

read_stsc(<<ChunkId:32, SamplesPerChunk:32, _SampleId:32, Rest/binary>>, EntryCount, Frames, Id) ->
  <<NextChunk:32, _/binary>> = Rest,
  NextId = set_chunk_id(ChunkId, SamplesPerChunk, NextChunk, Frames, Id),
  read_stsc(Rest, EntryCount - 1, Frames, NextId).

% STSS atom
% List of keyframes
stss(<<0:8, _Flags:3/binary, SampleCount:32, Samples/binary>>, #mp4_track{frames = Frames} = Mp4Track) ->
  read_stss(Samples, SampleCount, Frames),
  Mp4Track.

read_stss(_, 0, _Frames) ->
  ok;

read_stss(<<Sample:32, Rest/binary>>, EntryCount, Frames) ->
  set_frame(Frames, Sample - 1, #mp4_frame.keyframe, true),
  read_stss(Rest, EntryCount - 1, Frames).



% CTTS atom, list of B-Frames offsets
ctts(<<0:32, Count:32, CTTS/binary>>, #mp4_track{frames = Frames, timescale = Timescale} = Mp4Track) ->
  read_ctts(CTTS, Count, Frames, 0, Timescale),
  Mp4Track.

read_ctts(_, 0, _Frames, _, _) ->
  ok;

read_ctts(<<Count:32, Offset:32, Rest/binary>>, EntryCount, Frames, Id, Timescale) ->
  set_frames(Frames, Id, #mp4_frame.composition, Offset*1000/Timescale, Count),
  read_ctts(Rest, EntryCount - 1, Frames, Id + Count, Timescale).
  

% STCO atom
% sample table chunk offset
stco(<<0:8, _Flags:3/binary, OffsetCount:32, Offsets/binary>>, #mp4_track{frames = Frames} = Mp4Track) ->
  read_stco(Offsets, OffsetCount, Frames, 0, 0),
  Mp4Track.

read_stco(_, 0, _Frames, _FrameId, _ChunkId) ->
  ok;

read_stco(<<Offset:32, Rest/binary>>, OffsetCount, Frames, FrameId, ChunkId) ->
  SampleCount = length(ets:match(Frames, #mp4_frame{id = '_', dts = '_', size = '_', chunk_id = ChunkId, composition = '_', keyframe = '_', offset = '_'})),
  read_stco_samples(Offset, Frames, SampleCount, FrameId),
  read_stco(Rest, OffsetCount - 1, Frames, FrameId + SampleCount, ChunkId + 1).

read_stco_samples(_, _, 0, _) ->
  ok;
  
read_stco_samples(Offset, Frames, SampleCount, Id) ->
  Size = ets:lookup_element(Frames, Id, #mp4_frame.size),
  ets:update_element(Frames, Id, {#mp4_frame.offset, Offset}),
  read_stco_samples(Offset + Size, Frames, SampleCount - 1, Id + 1).

extract_language(<<L1:5, L2:5, L3:5, _:1>>) ->
  [L1+16#60, L2+16#60, L3+16#60].



fill_track_info(MediaInfo, #mp4_track{data_format = avc1, decoder_config = DecoderConfig, width = Width, height = Height, frames = Frames} = _Track) ->
  % copy_track_info(MediaInfo#media_info{video_decoder_config = DecoderConfig, width = Width, height = Height, video}, Track);
  MediaInfo#media_info{video_decoder_config = DecoderConfig, width = Width, height = Height, video_track = Frames};


fill_track_info(MediaInfo, #mp4_track{data_format = mp4a, decoder_config = DecoderConfig, frames = Frames} = _Track) ->
  % copy_track_info(MediaInfo#media_info{audio_decoder_config = DecoderConfig}, Track);
  MediaInfo#media_info{audio_decoder_config = DecoderConfig, audio_track = Frames};
  
fill_track_info(MediaInfo, #mp4_track{data_format = Unknown}) ->
  ?D({"Uknown data format", Unknown}),
  MediaInfo.


copy_track_info(#media_info{frames = FileFrames} = MediaInfo, #mp4_track{timescale = Timescale, frames = Frames, data_format = DataFormat}) ->
  Type = case DataFormat of
    avc1 -> video;
    mp4a -> audio
  end,
  copy_track_info(FileFrames, Frames, Timescale, Type, 0),
  MediaInfo.

copy_track_info(FileFrames, Frames, Timescale, Type, Id) ->
  case file_frame_from_track(Frames, Id, Timescale, Type) of
    undefined ->
      ok;
    Frame ->
      ets:insert(FileFrames, Frame),
      copy_track_info(FileFrames, Frames, Timescale, Type, Id + 1)
  end.
  
  
file_frame_from_track(Frames, Id, Timescale, Type) ->
  case ets:lookup(Frames, Id) of
    [#mp4_frame{dts = DTS, size = Size, composition = CTime, keyframe = Keyframe, offset = Offset}] ->
      TimestampMS = DTS * 1000 / Timescale,
      % ?D({Type, DTS, Timescale}),
      FrameId = case Type of
        video -> round(TimestampMS)*3 + 1 + 3;
        audio -> round(TimestampMS)*3 + 2 + 3
      end,
      
      #file_frame{id = FrameId, dts = TimestampMS, type = Type, offset = Offset, size = Size, keyframe = Keyframe, pts = (DTS + CTime)*1000/Timescale};
    [] ->
      undefined
  end.
  
      
  

mp4_desc_length(<<0:1, Length:7, Rest:Length/binary, Rest2/binary>>) ->
  {Rest, Rest2};

mp4_desc_length(<<1:1, Length1:7, 0:1, Length:7, Rest/binary>>) ->
  TagLength = Length1 * 128 + Length,
  <<Rest1:TagLength/binary, Rest2/binary>> = Rest,
  {Rest1, Rest2};

mp4_desc_length(<<1:1, Length2:7, 1:1, Length1:7, 0:1, Length:7, Rest/binary>>)  ->
  TagLength = (Length2 bsl 14 + Length1 bsl 7 + Length),
  <<Rest1:TagLength/binary, Rest2/binary>> = Rest,
  {Rest1, Rest2};

mp4_desc_length(<<1:1, Length3:7, 1:1, Length2:7, 1:1, Length1:7, 0:1, Length:7, Rest/binary>>)  ->
  TagLength = (Length3 bsl 21 + Length2 bsl 14 + Length1 bsl 7 + Length),
  <<Rest1:TagLength/binary, Rest2/binary>> = Rest,
  {Rest1, Rest2}.

mp4_read_tag(<<>>) ->
  undefined;
  
mp4_read_tag(<<Tag, Data/binary>>) ->
  {Body, Rest} = mp4_desc_length(Data),
  {Tag, Body, Rest}.

%% FIXME: Code here must be relocated in some more generic place and way. 
%% Here goes not some esds tag, but IOD (Initial Object Description)
%% Look how to parse it at vlc/modules/demux/ts.c:2400
%%

config_from_esds_tag(Data) ->
  case mp4_read_tag(Data) of
    {?MP4ESDescrTag, <<_ID1:16, _Priority1, Description/binary>>, <<>>} ->
      config_from_esds_tag(Description);
    {?MP4DecConfigDescrTag, <<_ObjectType, _StreamType, _BufferSize:24, _MaxBitrate:32, _AvgBitrate:32>>, Rest} ->
      config_from_esds_tag(Rest);
    {?MP4DecConfigDescrTag, <<_:13/binary, Rest1/binary>>, Rest2} when size(Rest1) > 0 ->
      case config_from_esds_tag(Rest1) of
        undefined ->
          config_from_esds_tag(Rest2);
        Config ->
          Config
      end;
    {?MP4DecSpecificDescrTag, Config, _} ->
      Config;
    {_Tag, _Data, Rest} ->
      ?D({"Unknown esds tag. Send this line to max@maxidoors.ru: ", _Tag, _Data}),
      config_from_esds_tag(Rest);
    undefined ->
      undefined
  end.

  
%%
%% Tests
%%
-include_lib("eunit/include/eunit.hrl").

mp4_desc_tag_with_length_test() ->
  ?assertEqual({3, <<0,2,0,4,13,64,21,0,0,0,0,0,100,239,0,0,0,0,6,1,2>>, <<>>}, mp4_read_tag(<<3,21,0,2,0,4,13,64,21,0,0,0,0,0,100,239,0,0,0,0,6,1,2>>)),
  ?assertEqual({4, <<64,21,0,0,0,0,0,100,239,0,0,0,0>>, <<6,1,2>>}, mp4_read_tag(<<4,13,64,21,0,0,0,0,0,100,239,0,0,0,0,6,1,2>>)).
  

esds_tag_test() ->
  ?assertEqual(undefined, config_from_esds_tag(<<3,21,0,2,0,4,13,64,21,0,0,0,0,0,100,239,0,0,0,0,6,1,2>>)),
  ?assertEqual(<<18,16>>, config_from_esds_tag(<<3,25,0,0,0,4,17,64,21,0,1,172,0,2,33,88,0,1,142,56,5,2,18,16,6,1,2>>)).
