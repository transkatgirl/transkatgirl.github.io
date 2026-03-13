#!/bin/bash
# "Ethereal Dreams" by minimax m2.5; modified by transkatgirl

DURATION=60

  #synth $DURATION sine mix 110 \
  #synth $DURATION sine mix 165 \
  #synth $DURATION sine mix 220 \
  #synth $DURATION sine mix 330 \
  #synth $DURATION sine mix 55 \
  #reverb 40 \

sox -c 2 -n audio.wav \
	synth $DURATION brownnoise mix \
	synth $DURATION sine mix 20 \
	reverb 50 \
	vol -6 dB

ffmpeg -y -colorspace bt709 -color_range tv -color_primaries bt709 -color_trc bt709 -f lavfi \
	-i "testsrc=duration=$DURATION:size=1920x1080:rate=30" \
	-f lavfi -i "cellauto=rule=110:s=1920x1080:seed=42" \
	-f lavfi -i "cellauto=rule=30:s=1920x1080:seed=137" \
	-i audio.wav \
	-filter_complex "
		[0:v]hue=s=sin(t/4):h=t/6[test_hued];
		[1:v]hue=h=t/10:s=2[cell1_hued];
		[2:v]hue=h=t/10+0.5:s=2[cell2_hued];
		[cell1_hued][cell2_hued]blend=all_mode=lighten:all_opacity=0.7[blend];
		[test_hued][blend]blend=all_mode=overlay:all_opacity=0.4[final];
		[final]vignette=angle=0.5+0.3*sin(t/5),scale=out_color_matrix=bt709:out_range=tv,format=yuv420p[out];
	" -t $DURATION -map "[out]" -map 3:a -c:v libx265 -c:a aac_at -shortest \
	-crf 18 -preset slow -b:a 320k -movflags +faststart ethereal_dreams.mp4

rm -f audio.wav