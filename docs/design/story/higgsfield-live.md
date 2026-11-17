# Higgsfield catalogue digest (live)

Read through the connector on 16 Nov 2026. The connector in this session is read-only (balance, model catalogue, finished generations, import of a Claude Motion MP4): it cannot start a generation or upload a reference image. Balance: 10 credits, free plan.

Catalogue size: image 51, video 60, audio 11, 3d 18 (140 entries; some ids are duplicates of one model, e.g. soul_2 = soul_v2, image_to_3d = meshy_image_to_3d). Raw pages: `story/higgsfield-raw/<type>-<page>.json`. "Sound" = the model has an audio switch or native-audio tag. "unlim" = catalogue flag `supports_unlim` (meaning not explained). Blank fields = catalogue states nothing.

## (a) Photoreal stills, concept art, character sheets
| id | name | provider | inputs | resolution | aspect ratios | notes |
|---|---|---|---|---|---|---|
| soul_cinematic | Soul Cinema | Higgsfield | image x1; soul_id (Soul Cinema Character ID) | 1.5k/2k | 1:1,4:3,3:4,16:9,9:16,3:2,2:3,21:9 | "Cinema-grade stills and concept art" |
| soul_2 / soul_v2 | Higgsfield Soul 2.0 | Higgsfield | image x1; soul_id; style_id (not with image refs) | 1.5k/2k | 1:1,16:9,9:16,4:3,3:4,3:2,2:3 | realistic character/portrait; unlim |
| cinematic_studio_2_5 | Cinema Studio Image 2.5 | Higgsfield | image | 1k/2k/4k | 10 ratios incl. 21:9 | cinematic stills |
| cinematic_studio_image | Cinematic Studio Image | (none) | image_references max 4 | 1k/2k/4k | 8 incl. 21:9 | REQUIRES camera_model_id, camera_lens_id, camera_focal_length_id preset ids |
| soul_location / cinematic_studio_soul_location | Soul Location | Higgsfield | text only | | up to 9:21/21:9 | environments, backgrounds |
| nano_banana_pro | Nano Banana Pro | Google | image_references max 14 | 1k/2k/4k | 10 incl. 21:9 | photoreal, text, diagrams; unlim |
| nano_banana_2_1 | Nano Banana 2.1 | Google | image_references max 14, mask, video_references max 1; seed | 1k/2k/4k | 15 incl. 4:1, 8:1 | thinking_level, web/image search; unlim |
| nano_banana_2 / nano_banana_2_lite / nano_banana | Nano Banana 2 / Lite / Nano Banana | Google | image_references (+mask on 2, Lite); Nano Banana max 8 | 2: 1k-4k; Lite 1k | ~10 | budget/fast tiers |
| nano_banana_2_shots | Nano Banana Pro | (none) | image_references exactly 1 | | 11 | "expand into multiple shots" (coverage from one frame) |
| flux_2 | FLUX.2 | Black Forest Labs | image_references | 1k/2k | 5 | variants pro/flex/max |
| flux_3_image | FLUX 3 Image | Black Forest Labs | image_references max 10 | 768sq-4k | 15 | batch 1-4 |
| minimax_h3_image | MiniMax H3 Image | MiniMax | image_references max 16 | 1k/2k/4k (default 4k) | not listed | batch 1-4 |
| kling_omni_image | Kling O1 Image | Kling | image_references max 10 | 1k/2k | 9 | photoreal |
| seedream_v4_5 / seedream_v5_pro / seedream_5_5 | Seedream 4.5 / 5.0 Pro / 5.5 | Bytedance | image_references max 14 / 10 / 10 | 4.5: up to ~6K; others up to 2k | 6-9 | 5.0 Pro: remove_bg, is_inpaint; 5.5: transparent PNG |
| grok_image / grok_image_2_0 | Grok Image / 2.0 | xAI | image_references (2.0: max 3) | 1k/2k | 10 | high-contrast |
| z_image | Z Image | Tongyi-MAI | text only | | 5 | fast stylized |
| soul_cast / cinematic_studio_soul_cast | Soul Cast | Higgsfield | text only, budget 10-500 | | soul_cast 16:9 only | "consistent cinematic character identity" (generates a cast persona) |
| image_auto | Auto | Higgsfield | image | | 5 | routes to a model |
Character sheets: no dedicated catalogue model; the Higgsfield server text names a "character-sheet" workflow (not a model).

## (b) Same face and clothes across many pictures and clips
| id | how references are taken | limits |
|---|---|---|
| soul_2 / soul_v2 | `soul_id` (Soul-ID, "get one from soul_list") + optional 1 image | style_id not compatible with image refs |
| soul_cinematic | `soul_id` = Soul Cinema Character ID | 1 image |
| soul_cinema_studio | `custom_reference_id` (saved character or style ref) + image_references | 1.5k/2k |
| kling4_0 / kling_4_0_flash | `kling_element_ids` (up to 7 ready Kling elements) + image_references max 10 | 4.0: 3-30 s, 720p/1080p; Flash 3-20 s, 720p |
| kling_o3_image_reference | Kling 3.0 Omni: image_references max 7 | 3-15 s, std/pro/4k, sound, multi-shot |
| seedance_2_0 | image_references (max 9 incl. start/end) + video_references (max 3, 2-15 s) + audio_references | tags "identity, consistent"; 4-15 s |
| seedance_2_5 / seedance_2_5_flash / cinematic_studio_video_4_0 | mode omni_reference: image_references up to 30 (incl. start/end), video max 10, audio max 10 (Flash: 10/5/5) | 4-30 s |
| wan3_0 / wan3_0_prime | image_references max 10, video max 5, audio max 5 | start_image cannot be combined with reference media |
| wan2_7 | start/end image + audio_references | tagged "character-consistent" |
| minimax_h3 / minimax_h3_max | image_references 9 / 12, video 3 / 12, audio 3 / 12 | H3 2K only; Max 480p/768p |
| grok_video_v15 | image_references max 7 (+ audio_references) | 2-15 s |
| gemini_omni_flash_1_2 | reference-to-video: image_references max 7, video max 3 | 3-10 s with refs |
| nano_banana_pro / nano_banana_2_1 / gpt_image_2_5 / gpt_image_2_6 / minimax_h3_image | image_references 14 / 14 / 16 / 16 / 16 | stills only |
| intone | character_images (1-2, readable front face) | talking head, see (d) |
Voice identity: `voice_type=element` + `voice_id` reuses a workspace voice element (Qwen, Eleven v4, Seed Audio, text2speech_v2, voice_change).

## (c) Image-to-video: start frame, start + end frame, intermediate frames
| id | name | provider | frames | duration | resolution | aspect | sound | notes |
|---|---|---|---|---|---|---|---|---|
| kling4_0 | Kling 4.0 | Kling | start, end, image_references = ordered middle frames (10 images total) | 3-30 s | 720p/1080p | 21:9,16:9,9:16,1:1,auto | not stated | longest keyframe chain |
| flux_3_video | FLUX 3 Video | Black Forest Labs | start, end (needs start), image_references = ordered intermediate frames max 10; video continuation | 5-20 s | 720p-4k | 8 incl. 21:9 | yes (default on) | |
| seedance_2_5 | Seedance 2.5 | Bytedance | start, end (omni_reference mode only) | 4-30 s | 480p-4k | 7 | yes | draft 480p then finalize; video_extension |
| seedance_2_5_flash | Seedance 2.5 Flash | Bytedance | start, end (omni_reference) | 4-30 s | 480p/720p | 7 | yes | |
| cinematic_studio_video_4_0 | Cinema Studio 4.0 | Higgsfield | start, end (omni_reference) | 4-30 s | 480p-1080p | 7 | yes | era/camera/lens/genre_id/light/palette controls |
| cinematic_studio_video_3_5 | Cinematic Studio Video 3.5 | (none) | start, end, refs (15 media total) | min 4 s, default 15, no max stated | 480p-1080p | 7 | yes (default off) | genre incl. horror; prompt_language default zh |
| seedance_2_0 | Seedance 2.0 | Bytedance | start, end | 4-15 s | 480p-4k | 7 | yes | mode std needs Plus plan or higher; fast from Basic/Starter |
| seedance_2_0_mini | Seedance 2.0 Mini | Bytedance | start, end | 4-15 s | 480p/720p | 7 | yes | budget |
| wan3_0 / wan3_0_prime | Wan 3.0 / Prime | Wan | start, end (needs start) | 2-30 s | 480p-1080p | 6 | yes | -1 smart duration only for unlimited |
| wan2_7 | Wan 2.7 | Wan | start, end | 2-15 s | 720p/1080p | 5 | yes | |
| kling_o3_flf | Kling 3.0 Omni (Frames) | Kling | start, end (needs start) | 3-15 s | std/pro/4k | 16:9,9:16,1:1 | yes | multi-shot |
| kling3_0 | Kling v3.0 | Kling | start, end | 3-15 s | std/pro/4k | 3 | yes | sound off = fewer credits |
| cinematic_studio_3_0 | Cinema Studio Video 3.0 | Higgsfield | image, start, end | 4-15 s | 480p-4k | 7 | yes (default off) | genre incl. horror |
| cinematic_studio_video_v2 | Cinema Studio Video | Higgsfield | image, start, end | 3-12 s | pro/std | 5 | yes | genre horror/suspense, speedramp, cfg_scale |
| cinematic_studio_video | Cinema Studio Video | Higgsfield | image, start, end | 5 or 10 s | | 5 | yes | slow_motion |
| minimax_h3 / minimax_h3_max | MiniMax H3 / Max | MiniMax | start, end (needs start) + refs | 4-15 / 5-15 s | 2K / 480p,768p | 7 | via audio refs | batch 1-4 |
| minimax_hailuo | Minimax Hailuo | Hailuo | start, end (not at 512) | 6 or 10 s | 512/768/1080 | | | facial emotion |
| gemini_omni_flash_1_1 / _1_2 | Gemini Omni Flash 1.1 / 1.2 | Google | start, optional end | 1.1: 3-10 s; 1.2: 3-15 s start only, 3-10 s with end | 360p-4k | 16:9,9:16 | yes | 1.2 can extend clips |
| veo3_1_lite | Google Veo 3.1 Lite | Google | start, end | 4/6/8 s | | 16:9,9:16,auto | optional | budget |
| veo3_1 | Google Veo 3.1 | Google | start only | 4/6/8 s | basic/high/ultra | 16:9,9:16 | tag "audio" | |
| kling2_6, kling3_0_turbo, grok_video, grok_video_v15(_lite), happy_horse_video | various | Kling/xAI/Happy Horse | start only | up to 10-15 s | up to 1080p | | mostly yes | |
| higgsfield_preset | Higgsfield Preset | Higgsfield | image x1 + preset_id required | | | 3 | | legacy |
Motion transfer: hf_mult_motion_control (Genjutsu, 1-49 subject images + 1 motion video), hf_mult_motion_control_flash (1-10 images, max 15 s), kling3_0_motion_control (1 image + 1 video). draw_to_video animates a sketch driven by a source video.

## (d) Lip-sync to supplied audio, voice tools
| id | name | inputs | limits |
|---|---|---|---|
| intone | Higgsfield Intone | character_images 1-2, optional location_image, audio_references 1-6 voice files | talking head, 1-2 characters, up to 5 shots; voices 2-30 s total, output 4-30 s (voices + 2.5 s); 480p-1080p; 6 ratios |
| sync_so | Sync Lipsync 3 | input_video + input_audio | sync_mode bounce/loop/cut_off/silence/remap; active speaker detection; up to 100 segments |
| seedance_2_0 / 2_5, wan2_7, wan3_0, minimax_h3, grok_video_v15, cinematic_studio_video_4_0 | (video models) | audio_references alongside images | audio-conditioned, not stated as exact lip-sync |
| voice_change | voice_change | input_video; voice_id + voice_type preset/element | replaces the voice in a video |
| dubbing | dubbing | input_video; target_language (18 languages) | re-voices speech |
| audio_dubbing | Audio Dubbing (ElevenLabs) | 1 audio; target_language | WAV out; transcript option needs ElevenLabs Enterprise |

## (e) Speech, sound effects, music (audio list, all 11)
| id | name | provider | what | key params / limits |
|---|---|---|---|---|
| elevenlabs_v4 | Eleven v4 | ElevenLabs | speech/dialogue | up to 10 voices, 10,000 chars, stability, batch 1-4 |
| elevenlabs_v4_turbo | Eleven v4 Turbo | ElevenLabs | speech | one voice, 10,000 chars |
| qwen_audio_tts | Qwen Audio 3.0 TTS Flash | Alibaba Cloud | speech | preset or cloned voice; instruction (emotion) max 128 chars; 13 languages |
| seed_audio | Seed Audio 1.0 | ByteDance | text-to-audio/speech | voice preset/element, up to 3 audio refs or 1 image ref; pitch/speed; wav/mp3; unlim |
| text2speech_v2 | Text to Speech V2 | Higgsfield | speech | engines elevenlabs, minimax, seed_speech, vibe_voice, cozy_voice; unlim |
| inworld_text_to_speech | Inworld Text to Speech | FAL | speech | ~100 named voices; "Game pipeline only" |
| mirelo_text_to_audio | Mirelo Text to Audio | FAL | sound effects | duration required; "Game pipeline only" |
| elevenlabs_music_v2 / _v2_5 | ElevenLabs Music v2 / v2.5 | ElevenLabs | music | 3-600 s; lyrics up to 120 s; instrumental; batch 1-4 |
| sonilo_music | Sonilo Music | FAL | music | duration required; "Game pipeline only" |
| audio_dubbing | Audio Dubbing | ElevenLabs | dubbing | see (d) |

## (f) Readable text in pictures
| id | name | notes |
|---|---|---|
| gpt_image_2_6 / gpt_image_2_6_flare | GPT Image 2.6 (Sunburst) / Flare | text-rendering; png/jpeg/webp/gif/svg; transparent bg; quality to max; 1k-4k; refs max 16 (not for SVG); 2.6 unlim |
| gpt_image_2_5 / gpt_image_2 | GPT Image 2.5 / 2 | text-rendering; 1k-4k; 2.5 refs max 16 |
| openai_hazel | OpenAI Hazel | "best text rendering"; refs max 16; ratios 1:1,3:2,2:3,auto only |
| ideogram_4_5 | Ideogram 4.5 | typography; up to 5 source images + mask; 24 ratios; seed |
| nano_banana_pro | Nano Banana Pro | text and diagrams; 4k |
| recraft_v4_1 | Recraft V4.1 | typography/vector; colour palette; text only |
| ideogram_vector / recraft_v4_styles | Ideogram Vector / Recraft V4 Styles | SVG generate or vectorize / saved style required |
| marketing_studio_2_image | Marketing Studio Product Shot | type=poster option (product-oriented) |

## (g) Editing, inpainting, outpainting, upscaling, background removal
- Inpaint with mask: nano_banana_2, nano_banana_2_1, nano_banana_2_lite (`is_inpaint` + mask), ideogram_4_5 (mask: black edited), seedream_v5_pro / 3d_jutsu_angles (`is_inpaint`).
- Instruction edits: flux_kontext (refs max 4), seedream_v5_lite, seedream_5_0_flash, flux_3_image, gpt_image_2_x, grok_image(s).
- Outpaint: flux_2_pro_outpaint (per-side pixels, up to 2048; negative = crop, all-crop free), outpaint (to a target ratio).
- Upscale image: topaz_image (Standard V2, Low Resolution V2, CGI, High Fidelity V2, Text Refine; face enhancement), topaz_image_generative (Redefine, Recovery, Wonder...), bytedance_image_upscale (2k/4k, optional remove_bg).
- Background removal: image_background_remover, seedream_v5_pro remove_bg, seedream_5_5 / gpt_image_2_6 transparent; video: video_background_remover, sam_3_video.
- Other image: image_decompose (layers), 3d_jutsu_angles (new angles), image_command (/polish), image_auto.
- Video editing: flux_3_video_edit (first 15 s; "costs 1 credit per second of the processed clip"), kling_video_edit, seedance_2_5 video_edit/extension, gemini_omni_flash_1_2 edit/extend, kling4_0 video-edit, hf_mult_replace_object(_flash), reframe, ad_multiplier(_v2).
- Video finishing: topaz_video (1080p/2160p, interpolation), bytedance_video_upscale (preset old_film etc.), video_upscale, video_deflicker, fps_boost, topaz_hyperion_2_5 (SDR to HDR), depth_anything_video.

## (h) 3D (all 18; output GLB unless noted)
| id | name | provider | input | notable options |
|---|---|---|---|---|
| meshy_v7_image_to_3d | Meshy 7 Image to 3D | Meshy | 1 image | standard/lowpoly, quad/tri, 100-300k polys, PBR, a/t-pose, rigging, 697 animations, ultra_mode |
| image_to_3d / meshy_image_to_3d | Image to 3D | Meshy | 1 image | texture (costs more), PBR, rigging, animation |
| multi_image_to_3d / meshy_multi_image_to_3d | Multi-Image to 3D | Meshy | 1-4 views | same as above |
| meshy_v6_text_to_3d | Meshy 6 Text to 3D | Meshy | text | preview/full, rigging, animation, texture_image_url |
| tripo_h3_1_image_to_3d / tripo_h3_1_multiview_to_3d | Tripo H3.1 | Tripo | 1 image / 2-4 views (front, left, back, right) | up to 2M faces, quad, PBR |
| tripo_p2_image_to_3d | Tripo P2 Image to 3D | Tripo | 1 image | output GLB or FBX; max 50k faces; delight; UV |
| tripo_3d | Text to 3D | (none) | text | negative_prompt, up to 2M faces |
| hunyuan3d_v3_image_to_3d | Hunyuan3D v3 | Tencent | 1-4 views (front, back, left, right) | 40k-1.5M faces, LowPoly, Geometry-only |
| hunyuan3d_v3_1_text_to_3d | Hunyuan 3D v3.1 Text to 3D | Tencent | text | std/pro, PBR pro only |
| sam_3_3d | SAM 3 3D Objects | Meta | 1 image | textured or white GLB |
| sam_3_3d_body | 3D Body | Meta | 1 image (+mask) | human body/pose GLB, PLY meshes |
| 3d_rigging / meshy_rigging | 3D Rigging | Meshy | model_url (GLB) | skeleton + animation |
| meshy_v5_remesh / meshy_v5_retexture | Meshy 5 Remesh / Retexture | Meshy | model_url | retopology / restyle textures |
Note: Meshy rigging "works best on humanoid"; non-bipeds may rig poorly.

## Best candidates for this project
**Boy in grey hoodie and red beanie, identical across ~12 clips.** Build a locked reference set first (Soul Cinema `soul_cinematic` with a Soul Cinema Character `soul_id`, or Nano Banana Pro / GPT Image 2.6 from up to 14-16 refs), then animate with a reference-driven video model: `kling4_0` (up to 7 saved `kling_element_ids` plus 10 images, 3-30 s, 1080p), `seedance_2_5` / `cinematic_studio_video_4_0` (omni_reference, up to 30 image refs, 4-30 s), or `seedance_2_0` (tagged identity/consistent, but std mode needs Plus plan). Using the same reference set in every clip is what keeps him identical; the catalogue promises no exact consistency.

**Slow change from boy to tall, thin figure in a cracked porcelain mask (start + end frame).** Start and end both allowed by: kling4_0 (3-30 s, plus ordered middle frames, the best fit for a controlled multi-stage change), flux_3_video (5-20 s, up to 10 intermediate frames, up to 4k), seedance_2_5 / _flash and cinematic_studio_video_4_0 (4-30 s, omni_reference mode), wan3_0 / wan3_0_prime (2-30 s), cinematic_studio_video_3_5 (from 4 s, default 15, genre horror), seedance_2_0 / mini (4-15 s), kling_o3_flf and kling3_0 (3-15 s), cinematic_studio_3_0 (4-15 s), minimax_h3 / max (4/5-15 s), gemini_omni_flash_1_1/1_2 (3-10 s with end frame), wan2_7 (2-15 s), minimax_hailuo (6/10 s), veo3_1_lite (4/6/8 s). veo3_1 takes a start frame only.

**Close shots speaking pre-recorded lines.** `intone` is made for this: 1-2 character images plus 1-6 recorded voice files (2-30 s total), 1080p, up to 5 shots. For an existing clip, `sync_so` (Sync Lipsync 3) re-syncs lips to a supplied audio track with speaker detection and per-segment timing. Voices can be produced with elevenlabs_v4 or qwen_audio_tts (cloned voice element).

**Small porcelain-faced creature hopping on asphalt.** Render a still (nano_banana_pro or soul_cinematic), then image-to-video with a physics-focused model: kling4_0 / kling3_0, seedance_2_5, minimax_hailuo (natural physics), or veo3_1. For a repeatable hop, hf_mult_motion_control (Genjutsu) transfers motion from a reference video to the creature image.

**Horror mood controls.** `genre` with a "horror" option: cinematic_studio_3_0, cinematic_studio_video_v2 (also "suspense", speedramp slowmo), cinematic_studio_video_3_5 (plus camera_style e.g. silent_machine, light_scheme silhouette/contre_jour, color_grading sodium_decay/cold_steel/bleach_bypass/classic_bw), seedance_2_0 and seedance_2_0_mini. cinematic_studio_video_4_0 takes `genre_id`, era, lens, custom light rig and palette (ids not listed in the catalogue).

**Posters and notices with readable text.** gpt_image_2_6 (or Flare) at high/xhigh quality up to 4k, openai_hazel ("best text rendering"), ideogram_4_5 (typography, mask edits), nano_banana_pro. Recraft V4.1 for clean vector signage.

**3D mesh of the monster's body or props.** meshy_v7_image_to_3d (rigging, a/t-pose, animations; humanoid rigging suits the tall figure), meshy_multi_image_to_3d or tripo_h3_1_multiview_to_3d / hunyuan3d_v3_image_to_3d from 2-4 turnaround views for better geometry, tripo_p2_image_to_3d if FBX is wanted, sam_3_3d for single props, meshy_v6_text_to_3d / tripo_3d from text. Rig later with meshy_rigging.

## Unknown or not in the catalogue
- Credit price per generation: not stated for any model, except flux_3_video_edit (1 credit per second processed) and flux_2_pro_outpaint (all-crop is free). Several say only "higher = more credits" or "adds cost".
- Which models the free plan (10 credits) may use: not stated. Only plan rule seen: seedance_2_0 mode std needs Plus plan or higher (Pro on legacy); fast from Basic/Starter.
- Meaning of `supports_unlim`, and smart duration (-1) "only for unlimited generations" on Wan 3.0.
- Ids for Soul-IDs, Kling elements, voice elements, presets, Cinema Studio 4.0 controls: catalogue points to tools (soul_list, get_presets, etc.) that this read-only connector does not offer.
- How Soul Cast takes a character (no media input, budget only); exact max duration of cinematic_studio_video_3_5; native audio on veo3_1 (tag only); aspect ratios for several edit/upscale tools.
- Video output frame rate and file format for most models; 3D export formats other than GLB (and FBX for Tripo P2).
- "Game pipeline only" (inworld, mirelo, sonilo) is not explained.
