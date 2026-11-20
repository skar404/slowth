# Эксперимент: можно ли различать скролл по движению телефона

Это Debug-инструмент для сбора данных, а не готовый детектор скролла. Он не меняет блокировки Slowth. Нужен физический iPhone с поддержкой `CMSensorRecorder`; симулятор годится только для просмотра интерфейса.

## Как запустить

1. Собрать и запустить схему **Debug - iOS** в Xcode. Открыть настройки → Debug → **Experiment: scroll motion**.
2. В списке сессий нажать **New recording**, выбрать длительность 1/3/5 минут и начальный тег. Можно выключить **Save screen video** для записи только датчиков.
3. Для видео нажать **Start recording** и подтвердить системный запуск трансляции. После первых кадров сессия датчиков начнётся автоматически, без второго Start и без 15-секундной подготовки. Если трансляция уже идёт, та же кнопка сразу присоединяет сессию.
4. Перейти в нужное приложение. Live Activity позволяет менять метку и остановить общую запись. Остановка трансляции, Stop recording и таймер завершают видео и анализируемый интервал датчиков вместе. 15 секунд подготовки остались только у режима без видео.
5. Открыть сессию в редакторе. Видео доступно независимо от выдачи Core Motion. В меню **… → Load recorded sensor data** импортировать датчики; при задержке повторить через несколько минут.
6. Коснуться таймлайна, выделить диапазон и назначить теги. Переключать горизонтальный/вертикальный режим, масштаб, скорость и покадровый шаг. Правки сохраняются автоматически.
7. Через **…** подготовить CSV, полный ZIP или обрезанный клип; передача выполняется только по явному действию.

Для прямого открытия экрана в Debug можно передать приложению аргумент запуска `--motion-experiment`.

## Контрольный набор

Записать по три одноминутные сессии каждого действия, перемешивая порядок:

| Метка | Что делать |
| --- | --- |
| `scroll` | Повторно листать ленту сидя, удерживая телефон одной рукой |
| `read` | Читать неподвижный текст в той же позе и тем же хватом |
| `type` | Печатать сообщение в той же позе |
| `walk` | Идти с телефоном в руке без скролла |
| `still` | Держать телефон спокойно; отдельно повторить на столе |

Дополнительно: скролл на столе, другая рука, обычная длинная статья, листание фото. Это проверяет, не научились ли мы замечать только хват/ходьбу и можно ли отличить ленту от другой прокрутки. Отдельные сессии удобнее смены меток: открытие Live Activity и нажатие кнопки сами двигают телефон. При смене метки исключать минимум 2 секунды до и после неё из последующего анализа.

## Как читать графики

- Оси X/Y/Z — сырое ускорение в единицах g, включая гравитацию. При наклоне телефона значения меняются без свайпа.
- Модуль `sqrt(x² + y² + z²)` обычно около 1 g у неподвижного телефона. В обзорном графике каждая вертикальная черта — минимум/максимум за секунду; это сохраняет короткие пики.
- На таймлайне сразу видны кадры, отдельные знаковые графики X/Y/Z и интервалы тегов. Оси имеют общую симметричную шкалу в g, которая расширяется по пикам; пропуски длиннее 100 мс разрывают линии. Загрузка датчиков начинается при открытии редактора независимо от видео.
- Пустое время — отсутствие данных, не неподвижность. Число отсчётов сравнивается с номинальными 50 Гц; `Largest missing interval` включает недостающие начало и конец сессии. Пустые секундные интервалы не соединяются линиями.
- Наличие таймера/Live Activity означает отправленный запрос записи. Только полученные отсчёты подтверждают сбор данных.

Ищем повторяющийся рисунок, который сохраняется в разных сессиях `scroll` и реже встречается в контролях. Совпадение нескольких пиков ещё не подтверждает детектор. Для будущей модели разделять обучение и проверку по целым сессиям/людям, не по соседним отсчётам. Распознавание повторных жестов само по себе не доказывает, что лента бесконечная.

## Ограничения и хранение

`CMSensorRecorder` записывает в фоне с номинальной частотой 50 Гц. Система хранит данные до трёх дней, выдача может отставать до трёх минут. Поэтому импортировать сессию нужно в течение трёх дней; импортированные JSON остаются в Application Support/MotionExperiment контейнера приложения. Повторный импорт объединяет данные, не стирая ранее сохранённые отсчёты при пустом ответе системы.

У API нет остановки текущего запроса. **End** завершает только размеченный интервал, и более поздние отсчёты не импортируются. Системный запрос заканчивается в изначально назначенное время, максимум через 5 минут 15 секунд для этого инструмента. Live Activity не предоставляет постоянное фоновое выполнение; этот эксперимент анализирует запись после сессии.

Разрешение движения добавлено только в Debug Info.plist; экран, код записи и дополнительная Live Activity исключены из Release через `#if DEBUG`. Версия и номер сборки не меняются для локальной проверки.

## Проверка реализации

```sh
xcrun swiftc -D DEBUG Debug/iOS/MotionExperimentData.swift Debug/iOS/MotionExperimentEdits.swift Debug/Shared/MotionVideoProtocol.swift tests/MotionExperiment/main.swift -o /tmp/slowth-motion-tests
/tmp/slowth-motion-tests
xcodegen generate
xcodebuild -project Unscroll.xcodeproj -scheme 'Debug - iOS' -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/slowth-motion-build CODE_SIGNING_ALLOWED=NO build
```

Проверки данных покрывают границы сессии, исключение setup, метки, пропуски, раннее завершение, CSV и сохранение. Сборка и синтетический график не подтверждают реальную фоновую запись: это проверяется сценарием выше на iPhone, отдельно включая блокировку экрана, уход в другое приложение и повторное открытие Slowth.

Источники Apple: [CMSensorRecorder](https://developer.apple.com/documentation/coremotion/cmsensorrecorder), [запись в фоне](https://developer.apple.com/documentation/coremotion/cmsensorrecorder/recordaccelerometer(forduration:)), [задержка данных](https://developer.apple.com/documentation/coremotion/cmsensorrecorder/accelerometerdata(from:to:)).

## Video and interval editor (Debug iOS)

The session list now opens a separate editor. New recording settings offer video + motion or motion only. For video, use the existing Slowth system broadcast picker and wait for **Live frames confirmed** before Start. Cancelling the picker does not create a session. The 15-second setup and 1/3/5-minute durations remain. Ending an experiment stops only its video saving; it never calls `finishBroadcastWithError` or changes blocking policy.

The editor shares a playhead, pixels-per-second zoom and selection between horizontal and vertical timelines. Video stays above the timeline. Tap to seek, use 0.25×/0.5×/1× playback and previous/next recorded frame, then Select to add a range. Drag either 44-point handle or enter seconds. Tags may overlap. The interval chips select an existing interval, replace its bounds with the current selection, or remove it. Manage tags to create, rename or recolor them. Stable UUIDs keep renames attached to existing intervals. Missing tags mean unlabelled. Trim, Full range, Undo and Redo change a sidecar, never the recording. Undo history lasts while the editor is open; the resulting edits persist across launches.

### Capture and clock contract

- `Debug/Shared/MotionVideoProtocol.swift`: versioned atomic App Group command, frame heartbeat and per-session `video.json`. The host writes commands; the broadcast extension owns video status. Commands include both wall-clock and uptime anchors to reject stale requests after reboot.
- `Debug/Broadcast/MotionVideoRecorder.swift`: silent H.264, even dimensions with longest side <=1280, <=30 fps. A nonblocking one-frame admission slot bounds retained ReplayKit buffers. Scaling and disk/encoder work use a separate utility queue. A queue timer enforces the deadline even if the host is suspended or ReplayKit is paused.
- Segments close at roughly 4 seconds, orientation/size changes, >250 ms frame gaps or clock discontinuities. Frames are rotated upright before encoding. Each finished MOV and its manifest entry are durable before the next segment. Interrupted capture preserves committed segments; the last incomplete segment may be lost. Low storage (80 MiB reserve), writer failure and interruption appear in session actions. Final status is `finishing` until the last writer callback completes, so exports cannot silently omit the final segment.
- The common axis starts at the end of setup. Each segment retains ReplayKit PTS, receipt uptime, orientation, dimensions and individual frame offsets. New motion samples retain Core Motion uptime alongside original Unix time. Timeline and tag assignment use sample uptime when available; old sessions fall back to Unix time.
- Video synchronization is anchored to the first frame's receipt uptime and then follows its PTS within that segment. This retains pauses and rotations but includes capture/dispatch latency. It is **not a measured hardware synchronization guarantee**. Session actions allow a signed manual video offset. Physical five-minute start/end alignment still needs measurement.
- Player composition inserts empty time ranges and letterboxes orientation changes. Missing video is explicitly covered by “No video at this time”; missing motion has no magnitude bars. Trimmed clips retain gaps as black video.

### Storage and exports

Original sessions/samples remain in Application Support/MotionExperiment. `<UUID>-edits.json` contains versioned trim, custom tags, interval IDs and video offset. Legacy sequential markers and Live Activity labels are migrated on opening; after the first explicit edit the sidecar is authoritative. Videos live under the shared App Group `MotionVideo/<UUID>/` and are owned by the extension. Sensor import remains separate, so delayed Core Motion data does not block opening or annotating video.

Session actions offer:

- **Prepare trimmed CSV**: original Unix time and original recording `label`, existing measurement columns, plus `trim_elapsed_seconds` and CSV-escaped `tags_json` containing all active tag IDs/names. Boundaries are half-open `[start, end)`.
- **Prepare full session ZIP**: immutable original samples, session metadata, editing sidecar, video synchronization manifest and every committed video file. The CSV in the archive reflects the trim; samples and video files remain full-length.
- **Export trimmed video clip**: silent MP4 from the useful range, leaving original MOVs intact.
- **Queue snapshot**: existing Debug Transfer now copies/clones video files into an immutable snapshot, hashes in chunks and uses URLSession file uploads. No whole video is materialized as `Data`. Queuing does not send; Send pending is still explicit.

Confirmed session deletion removes its original local video, samples and edits. Exported/queued copies are separate snapshots and remain managed by Files/Transfers.

### Validation and device checklist

Data checks:

```sh
xcrun swiftc -D DEBUG Debug/iOS/MotionExperimentData.swift Debug/iOS/MotionExperimentEdits.swift Debug/Shared/MotionVideoProtocol.swift tests/MotionExperiment/main.swift -o /tmp/slowth-motion-tests
/tmp/slowth-motion-tests
swift test --filter DebugTransferTests
python3 -m unittest discover -s tests -p 'test_*.py'
```

The tests cover legacy decoding, marker migration, overlapping tags, rename identity, interval boundaries, trim, undo/redo, sidecar round-trip, CSV quoting, pause gaps, rotation metadata, manual sync and streaming transfer to the real local HTTP receiver. Model tests do not exercise ReplayKit or AVAssetWriter on a phone.

Debug launch arguments: `--motion-experiment --motion-session <UUID>` opens an existing session. Add `--motion-vertical` for vertical layout. On Simulator only, `--motion-selection <start> <end>` selects a range for repeatable visual inspection. These arguments do not generate or upload data.

Physical acceptance remains separate from build success:

1. New broadcast, cancelled picker, and already-running broadcast; confirm sensors start only after live frames.
2. Switch apps for 1/3/5 minutes; confirm background deadline and ordinary Slowth blocking. End experiment and confirm the regular broadcast continues.
3. Pause/resume and rotate in both directions; stop the broadcast early; verify gaps plus later sensor import.
4. Interrupt the extension and test low free space; verify completed segments, truthful reason and export recovery.
5. Match visible motion events against sensor peaks at the beginning/end of a five-minute recording; record measured latency/drift and any offset used.
6. On compact iPhone and large screen, verify both axes, accurate handles, numerical bounds, zoom, playback position across switching, tag editing and relaunch persistence.

Local implementation verification (2026-11-20): Debug Simulator and signed iPhone builds passed; Release Simulator built and inspection found no Motion permission or experiment/video symbols in the host and extensions. Python suite: 121 passed. Swift runtime suite: 115 executed, 29 skipped, zero failures; this includes seven Debug Transfer tests and real localhost file transfer. Standalone motion model tests passed. Synthetic video/session rendering was inspected in horizontal and vertical iPhone layouts and vertical iPad layout. This verifies rendering, not touch precision or physical sensor/capture alignment. Native Simulator control was unavailable through the UI tool, so interactive gestures were not exercised. Signed Debug 2026.11.1 (34) was installed and launched on `chalk`; the physical checklist above is still outstanding.

2026-11-20 follow-up: fixed New recording remaining disabled after the session deadline. The list now refreshes its time-dependent status every second, and opening recording settings is always allowed. Only Start enforces the existing no-concurrent-session rule, with a visible deadline/busy explanation. Device crash inventory contained no new Slowth crash; restarting the prior build restored the form, confirmed by the user. The fixed deadline transition was visually checked in Simulator, and the signed Debug fix was installed on chalk. This does not qualify video capture or synchronization.


## Coupled start/stop and XYZ update

New video sessions now set `followsBroadcast=true`. A single **Start recording** control opens the ordinary system ReplayKit confirmation; a bounded host background task waits for confirmed frames and starts Core Motion automatically. Cancellation or timeout creates no session. For an already-running broadcast the same button attaches immediately after a fresh frame. New coupled sessions have no setup delay. Motion-only recording retains its 15-second setup. The selected 1/3/5-minute limit remains.

The extension persists actual end uptime/date and stop cause. The host reconciles these into the sensor session's half-open end boundary on reopening and while viewing it. Stop recording, Live Activity End, the timer, and a video capture failure request termination of the coupled broadcast after normal at-rest shields have been restored. A normal system broadcast stop also ends the coupled sensor interval. Legacy sessions without this flag retain the old independent-stop behavior.

ReplayKit's sample-handler termination API is `finishBroadcastWithError`; iOS may display its system termination notice when the timer or in-app End stops the broadcast. This is separate from a capture failure in the saved metadata. `CMSensorRecorder` cannot cancel a request already handed to the OS: it can continue until the original deadline, but samples after the shared stop time are excluded from import, playback analysis and export. No claim of immediate hardware shutdown is made.

The timeline now draws signed raw X/red, Y/green and Z/blue on separate synchronized tracks in both orientations, using one symmetric auto-expanding g scale. Each line breaks at >100 ms gaps. Motion is loaded automatically after video is ready; the inline Load motion control remains available if Core Motion has not returned its delayed data. Tests cover signed peaks, independent axes, gap segmentation, expanding scales, monotonic end reconciliation, unrelated-session rejection and legacy independent stopping.

Playback following: while Play is active the timeline scrolls at each playhead update, keeping the cursor centered where scroll bounds permit. It retains the selected zoom in both orientations, replacing the previous five-second jumps. Pause releases the automatic following so the graph can be inspected manually. Zoom/direction changes recenter on the current playhead. The scroll target is the timeline's actual layout bounds rather than offset-only marker views.
