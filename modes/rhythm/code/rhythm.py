from mpf.core.mode import Mode


class Rhythm(Mode):
    # Delay the visual chart start very slightly so the rhythm slide can render
    # before notes begin spawning.
    CHART_STARTED_DELAY_MS = 50

    def mode_init(self):
        settings = self.config.get("mode_settings", {})
        self.lead_in_ms = int(settings.get("lead_in_ms", 1800))
        self.travel_ms = int(settings.get("travel_ms", 1600))
        self.perfect_window_ms = int(settings.get("perfect_window_ms", 90))
        self.good_window_ms = int(settings.get("good_window_ms", 170))
        self.finish_hold_ms = int(settings.get("finish_hold_ms", 1600))
        self.song_key = str(settings.get("song", ""))
        self.song_bus = str(settings.get("song_bus", "music"))

        # This is an audio start offset only. It does not move note timings.
        self.audio_offset_ms = int(settings.get("audio_offset_ms", 0))
        self.lane_switches = dict(settings.get("lane_switches", {
            "left": "s_flipper_left",
            "center": "s_action_button",
            "right": "s_flipper_right",
        }))
        self._configured_chart = list(settings.get("chart", []))
        self._chart = []
        self._active_notes = {}
        self._active_holds = {}
        self._chart_started = False
        self._start_time = 0.0

    def mode_start(self, **kwargs):
        del kwargs

        # The base slide sends this back after it measures the exact preview
        # position, so rhythm can resume the selected song where it stopped.
        self.add_mode_event_handler(
            "selected_song_resume_position_captured",
            self._capture_selected_song_resume_position,
        )

        # Pause the selected preview first, then start the rhythm track on the
        # same bus. The base slide also catches bus replacement as a backup.
        self._post_selected_song_pause()
        self._post_rhythm_music_started()
        self._active_notes = {}
        self._active_holds = {}
        self._chart_started = False
        self._chart = self._build_chart()
        self._start_time = self.machine.clock.get_time()

        self._reset_player_state()
        self._register_lane_handlers()

        self.delay.add(ms=self.CHART_STARTED_DELAY_MS, callback=self._post_chart_started, name="rhythm_chart_started")

        for note in self._chart:
            # Spawn before the hit time so the slide can animate travel time.
            spawn_delay = max(0, note["time_ms"] - self.travel_ms)
            self.delay.add(
                ms=spawn_delay,
                callback=self._spawn_note,
                name=f"rhythm_spawn_{note['id']}",
                note=note,
            )

        finish_delay = 1000
        if self._chart:
            # Hold the mode open long enough for the final note's judgment window.
            finish_delay = max(note["end_time_ms"] for note in self._chart) + self.good_window_ms + 250
        self.delay.add(ms=finish_delay, callback=self._finish_chart, name="rhythm_finish")

    def mode_stop(self, **kwargs):
        del kwargs
        self._active_notes = {}
        self._active_holds = {}
        self._chart_started = False
        self._post_selected_song_resume()

    def _build_chart(self):
        chart = []
        for index, note in enumerate(self._configured_chart):
            lane = str(note.get("lane", "")).lower()
            if lane not in self.lane_switches:
                self.warning_log("Skipping rhythm note with unknown lane '%s'.", lane)
                continue
            duration_ms = max(0, int(note.get("duration_ms", 0)))
            chart.append({
                "id": index,
                "lane": lane,
                "time_ms": int(note.get("time_ms", 0)),
                "duration_ms": duration_ms,
                "end_time_ms": int(note.get("time_ms", 0)) + duration_ms,
            })
        chart.sort(key=lambda entry: (entry["time_ms"], entry["id"]))
        return chart

    def _register_lane_handlers(self):
        for lane, switch_name in self.lane_switches.items():
            press_handler = self.machine.switch_controller.add_switch_handler(
                switch_name,
                self._on_lane_pressed,
                callback_kwargs={"lane": lane},
            )
            release_handler = self.machine.switch_controller.add_switch_handler(
                switch_name,
                self._on_lane_released,
                state=0,
                callback_kwargs={"lane": lane},
            )
            self.switch_handlers.append(press_handler)
            self.switch_handlers.append(release_handler)

    def _reset_player_state(self):
        self.player.rhythm_mode_score = 0
        self.player.rhythm_combo = 0
        self.player.rhythm_best_combo = 0
        self.player.rhythm_hits = 0
        self.player.rhythm_misses = 0
        self.player.rhythm_notes_total = len(self._chart)
        self.player.rhythm_accuracy = 0
        self.player.rhythm_multiplier = 1

    def _post_selected_song_pause(self):
        payload = self._selected_song_payload()
        if payload:
            self.machine.events.post("selected_song_pause_for_rhythm", **payload)

    def _post_selected_song_resume(self):
        payload = self._selected_song_payload()
        if payload:
            self.machine.events.post("selected_song_resume_after_rhythm", **payload)

    def _post_rhythm_music_started(self):
        if not self.song_key:
            return

        # song_start_at is seconds because Godot audio playback uses seconds;
        # keep audio_offset_ms in the payload for UI/debugging if needed.
        self.machine.events.post(
            "rhythm_music_started",
            song_key=self.song_key,
            song_bus=self.song_bus,
            audio_offset_ms=self.audio_offset_ms,
            song_start_at=max(0.0, self.audio_offset_ms / 1000.0),
        )

    def _selected_song_payload(self):
        audio_path = str(getattr(self.player, "selected_song_path", "") or "")
        sound_key = str(getattr(self.player, "selected_song_key", "") or "")
        if not audio_path and not sound_key:
            return None

        # selected_song_resume_at is updated by the base slide after it captures
        # the real playback position before rhythm audio takes over.
        return {
            "genre": str(getattr(self.player, "selected_song_genre", "") or ""),
            "song_title": str(getattr(self.player, "selected_song_title", "") or ""),
            "sound_key": sound_key,
            "audio_path": audio_path,
            "song_bus": str(getattr(self.player, "selected_song_bus", self.song_bus) or self.song_bus),
            "song_start_at": float(
                getattr(
                    self.player,
                    "selected_song_resume_at",
                    getattr(self.player, "selected_song_start_at", 0),
                ) or 0
            ),
        }

    def _capture_selected_song_resume_position(self, resume_position=0, audio_path="", sound_key="", **kwargs):
        del kwargs
        selected_path = str(getattr(self.player, "selected_song_path", "") or "")
        selected_key = str(getattr(self.player, "selected_song_key", "") or "")

        # Ignore stale capture events from any song that is no longer selected.
        if audio_path and selected_path and str(audio_path) != selected_path:
            return
        if sound_key and selected_key and str(sound_key) != selected_key:
            return
        try:
            resume_at = float(resume_position or 0)
        except (TypeError, ValueError):
            return
        self.player.selected_song_resume_at = max(0.0, resume_at)

    def _post_chart_started(self):
        self._chart_started = True
        self.machine.events.post(
            "rhythm_chart_started",
            total_notes=len(self._chart),
            travel_ms=self.travel_ms,
            perfect_window_ms=self.perfect_window_ms,
            good_window_ms=self.good_window_ms,
            lead_in_ms=self.lead_in_ms,
            chart_started_delay_ms=self.CHART_STARTED_DELAY_MS,
            song_key=self.song_key,
            song_bus=self.song_bus,
            audio_offset_ms=self.audio_offset_ms,
            song_start_at=max(0.0, self.audio_offset_ms / 1000.0),
        )

    def _spawn_note(self, note):
        if not self.active:
            return

        active_note = dict(note)
        active_note["state"] = "pending"
        active_note["judgment"] = None
        active_note["delta_ms"] = None
        self._active_notes[note["id"]] = active_note
        self.delay.add(
            ms=self.travel_ms + self.good_window_ms,
            callback=self._expire_note,
            name=self._expire_delay_name(note["id"]),
            note_id=note["id"],
        )
        self.machine.events.post(
            "rhythm_note_spawned",
            note_id=note["id"],
            lane=note["lane"],
            travel_ms=self.travel_ms,
            hit_time_ms=note["time_ms"],
            duration_ms=note["duration_ms"],
            end_time_ms=note["end_time_ms"],
        )

    def _expire_note(self, note_id):
        note = self._active_notes.get(note_id)
        if note and note.get("state") == "pending":
            self._register_miss(note)

    def _on_lane_pressed(self, lane):
        if not self._chart_started:
            return

        self.machine.events.post("rhythm_lane_pressed", lane=lane)

        if lane in self._active_holds:
            return

        # Multiple notes can be visible in the same lane; judge the closest one.
        candidate = self._find_candidate_note(lane)
        if not candidate:
            return

        delta_ms = abs(self._current_chart_time_ms() - candidate["time_ms"])
        if delta_ms <= self.perfect_window_ms:
            judgment = "perfect"
        elif delta_ms <= self.good_window_ms:
            judgment = "good"
        else:
            return

        if candidate["duration_ms"] > 0:
            self._start_hold(candidate, judgment, delta_ms)
        else:
            self._register_hit(candidate, judgment, delta_ms)

    def _on_lane_released(self, lane):
        if not self._chart_started:
            return

        note = self._active_holds.get(lane)
        if not note:
            return

        if self._current_chart_time_ms() >= note["end_time_ms"]:
            self._complete_hold(note["id"])
            return

        self._register_miss(note)

    def _find_candidate_note(self, lane):
        lane_notes = [
            note for note in self._active_notes.values()
            if note["lane"] == lane and note.get("state") == "pending"
        ]
        if not lane_notes:
            return None
        current_time_ms = self._current_chart_time_ms()
        return min(lane_notes, key=lambda note: abs(note["time_ms"] - current_time_ms))

    def _start_hold(self, note, judgment, delta_ms):
        note["state"] = "holding"
        note["judgment"] = judgment
        note["delta_ms"] = delta_ms
        self._active_holds[note["lane"]] = note

        # A hold note should not expire while the player is actively holding it.
        self.delay.remove(self._expire_delay_name(note["id"]))

        remaining_ms = max(0, note["end_time_ms"] - self._current_chart_time_ms())
        self.delay.add(
            ms=remaining_ms,
            callback=self._complete_hold,
            name=self._hold_complete_delay_name(note["id"]),
            note_id=note["id"],
        )

        self.machine.events.post(
            "rhythm_hold_started",
            note_id=note["id"],
            lane=note["lane"],
            judgment=judgment,
            delta_ms=delta_ms,
            duration_ms=note["duration_ms"],
            end_time_ms=note["end_time_ms"],
            remaining_ms=remaining_ms,
        )

    def _complete_hold(self, note_id):
        note = self._active_notes.get(note_id)
        if not note or note.get("state") != "holding":
            return
        self._register_hit(note, note["judgment"], note["delta_ms"], is_hold=True)

    def _register_hit(self, note, judgment, delta_ms, is_hold=False):
        del is_hold
        self._remove_note_tracking(note)

        combo = self.player.rhythm_combo + 1

        # Multiplier steps up every 8 combo, capped so rhythm scoring stays bounded.
        multiplier = min(1 + ((combo - 1) // 8), 4)
        base_value = 20000 if judgment == "perfect" else 10000
        award = base_value * multiplier

        self.player.rhythm_combo = combo
        self.player.rhythm_best_combo = max(self.player.rhythm_best_combo, combo)
        self.player.rhythm_hits += 1
        self.player.rhythm_multiplier = multiplier
        self.player.rhythm_mode_score += award
        self.player.score += award

        self.machine.events.post(
            "rhythm_note_hit",
            note_id=note["id"],
            lane=note["lane"],
            judgment=judgment,
            combo=combo,
            multiplier=multiplier,
            award=award,
            delta_ms=delta_ms,
            total_score=self.player.rhythm_mode_score,
            is_hold=bool(note.get("duration_ms", 0)),
        )

    def _register_miss(self, note):
        self._remove_note_tracking(note)

        self.player.rhythm_combo = 0
        self.player.rhythm_misses += 1
        self.player.rhythm_multiplier = 1

        self.machine.events.post(
            "rhythm_note_missed",
            note_id=note["id"],
            lane=note["lane"],
            total_misses=self.player.rhythm_misses,
            is_hold=bool(note.get("duration_ms", 0)),
        )

    def _finish_chart(self):
        if not self.active:
            return

        for note in list(self._active_notes.values()):
            if note["id"] in self._active_notes:
                self._register_miss(note)

        total_notes = len(self._chart)
        accuracy = 0
        if total_notes:
            accuracy = round((self.player.rhythm_hits / total_notes) * 100)

        self.player.rhythm_accuracy = accuracy
        self.player.rhythm_multiplier = 1

        self.machine.events.post(
            "rhythm_mode_finished",
            total_notes=total_notes,
            hits=self.player.rhythm_hits,
            misses=self.player.rhythm_misses,
            best_combo=self.player.rhythm_best_combo,
            accuracy=accuracy,
            total_score=self.player.rhythm_mode_score,
        )

        self.delay.add(ms=self.finish_hold_ms, callback=self.stop, name="rhythm_stop")

    def _current_chart_time_ms(self):
        return round((self.machine.clock.get_time() - self._start_time) * 1000)

    def _remove_note_tracking(self, note):
        self._active_notes.pop(note["id"], None)
        self._active_holds.pop(note["lane"], None)
        self.delay.remove(self._expire_delay_name(note["id"]))
        self.delay.remove(self._hold_complete_delay_name(note["id"]))

    @staticmethod
    def _expire_delay_name(note_id):
        return f"rhythm_expire_{note_id}"

    @staticmethod
    def _hold_complete_delay_name(note_id):
        return f"rhythm_hold_complete_{note_id}"
