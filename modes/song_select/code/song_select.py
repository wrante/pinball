import random
from pathlib import Path

from mpf.core.mode import Mode


class SongSelect(Mode):
    # Song select discovers audio files directly from the music folders.
    AUDIO_EXTENSIONS = {".mp3", ".ogg", ".wav"}

    # The highlighted header is treated like a fake genre option for navigation.
    RANDOM_GENRE_INDEX = -1
    BACK_LABEL = "< BACK"
    PREVIEW_ENDED_EVENT = "song_select_preview_ended"

    # Re-post the slide across a few early frames so Godot/MPF display startup
    # timing does not briefly show the base slide before song select is ready.
    SLIDE_SHOW_DELAYS_MS = (1, 16, 40, 80)

    # MPF lifecycle and configuration setup.
    def mode_init(self):
        settings = self.config.get("mode_settings", {})
        self.select_switch = str(settings.get("select_switch", "s_action_button"))
        self.previous_switch = str(settings.get("previous_switch", "s_flipper_left"))
        self.next_switch = str(settings.get("next_switch", "s_flipper_right"))
        self.music_root = str(settings.get("music_root", "sounds/music/Genres"))
        self.song_bus = str(settings.get("song_bus", "music"))
        self.song_start_at = float(settings.get("song_start_at", 0))
        self.genres = []

        # Each highlighted genre previews one random song, then keeps that
        # same song selected if the player opens the genre.
        self.genre_preview_song_indices = {}

        # The header random choice is picked once on mode start so the song
        # already playing is the song selected if the player presses action.
        self.random_genre_index = None
        self.random_song_index = None
        self.genre_index = self.RANDOM_GENRE_INDEX
        self.song_index = 0
        self.stage = "genre"

    def mode_start(self, **kwargs):
        del kwargs
        self.genres = self._build_genres()
        self.genre_preview_song_indices = {}
        self._randomize_random_selection()
        self.genre_index = self.RANDOM_GENRE_INDEX
        self.song_index = 0
        self.stage = "genre"
        self._register_switch_handlers()
        self.add_mode_event_handler(self.PREVIEW_ENDED_EVENT, self._preview_ended)
        self._show_slide()

        # These retries are intentionally short. They smooth over startup
        # ordering between MPF mode events and the Godot display window.
        for index, delay_ms in enumerate(self.SLIDE_SHOW_DELAYS_MS):
            self.delay.add(
                ms=delay_ms,
                callback=self._show_slide,
                name="song_select_show_slide_%s" % index,
            )

    def _show_slide(self):
        self.machine.events.post("song_select_show_slide")
        self._post_update()

    # Music library discovery from the project folders or fallback config.
    def _build_genres(self):
        return self._build_genres_from_folder() or self._build_genres_from_config()

    def _build_genres_from_folder(self):
        root = self._resolve_music_root()
        if not root:
            self.warning_log("Song select music root '%s' was not found.", self.music_root)
            return []

        genres = []

        # The special "?" genre should be visually last, but every other folder
        # stays alphabetical so adding music only requires adding folders/files.
        for genre_dir in sorted(root.iterdir(), key=lambda path: self._genre_sort_key(path.name)):
            if not genre_dir.is_dir():
                continue

            audio_files = sorted(genre_dir.iterdir(), key=lambda path: path.stem.lower())
            songs = [
                self._song_from_path(song_path)
                for song_path in audio_files
                if self._is_audio_file(song_path)
            ]
            if songs:
                genres.append({"name": genre_dir.name, "songs": songs})

        if not genres:
            self.warning_log("Song select music root '%s' has no playable audio files.", root)
        return genres

    def _build_genres_from_config(self):
        genres = []
        configured_genres = self.config.get("mode_settings", {}).get("genres", {})

        # Configured fallback songs use the same order rules as folder songs.
        sorted_genres = sorted(
            configured_genres.items(),
            key=lambda entry: self._genre_sort_key(entry[0]),
        )
        for genre_name, songs in sorted_genres:
            clean_songs = [self._song_from_config(song) for song in songs]
            if clean_songs:
                genres.append({"name": str(genre_name), "songs": clean_songs})
        return genres

    def _genre_sort_key(self, genre_name):
        clean_name = str(genre_name).strip()
        return clean_name == "?", clean_name.lower()

    def _song_from_path(self, song_path):
        # Godot can load the direct res:// path, while sound_key remains as a
        # fallback for songs defined through MPF sound assets.
        return {
            "title": song_path.stem,
            "sound_key": song_path.stem,
            "audio_path": self._res_path(song_path),
            "has_audio": True,
        }

    def _song_from_config(self, song):
        if not isinstance(song, dict):
            # Plain strings are useful for testing layouts without audio.
            return {
                "title": str(song),
                "sound_key": "",
                "audio_path": "",
                "has_audio": False,
            }

        sound_key = str(song.get("sound_key", ""))
        audio_path = str(song.get("audio_path", ""))
        return {
            "title": str(song.get("title", "")),
            "sound_key": sound_key,
            "audio_path": audio_path,
            "has_audio": bool(sound_key or audio_path),
        }

    def _is_audio_file(self, path):
        return path.is_file() and path.suffix.lower() in self.AUDIO_EXTENSIONS

    def _resolve_music_root(self):
        machine_path = Path(str(getattr(self.machine, "machine_path", Path.cwd())))

        # Accept a few historical folder names so moving from music/genres to
        # sounds/music/Genres does not break older checkouts.
        candidates = [
            Path(self.music_root),
            Path("sounds/music/Genres"),
            Path("sounds/music/genres"),
            Path("music/genres"),
            Path("music/Genres"),
        ]

        for candidate in candidates:
            path = candidate if candidate.is_absolute() else machine_path / candidate
            if path.is_dir():
                return path
        return None

    def _res_path(self, path):
        machine_path = Path(str(getattr(self.machine, "machine_path", Path.cwd()))).resolve()
        try:
            relative_path = path.resolve().relative_to(machine_path)
        except ValueError:
            return ""
        return "res://%s" % relative_path.as_posix()

    # Switch registration and navigation.
    def _register_switch_handlers(self):
        handlers = [
            (self.previous_switch, self._previous),
            (self.next_switch, self._next),
            (self.select_switch, self._select),
        ]
        for switch_name, callback in handlers:
            handler = self.machine.switch_controller.add_switch_handler(switch_name, callback)
            self.switch_handlers.append(handler)

    def _previous(self):
        self._move(-1)

    def _next(self):
        self._move(1)

    def _move(self, direction):
        if not self.genres or self.stage == "confirmed":
            return

        if self.stage == "genre":
            self._move_genre_option(direction)
        else:
            self.song_index = (self.song_index + direction) % self._song_option_count()
            if not self._back_selected():
                # Remember the song position so backing out and re-entering a
                # genre returns to the same preview song.
                self.genre_preview_song_indices[self.genre_index] = self.song_index
        self._post_update()

    def _select(self):
        if not self.genres or self.stage == "confirmed":
            return

        if self.stage == "genre":
            self._select_genre_option()
        elif self._back_selected():
            self._back_to_genres()
        else:
            self._confirm_song(self.genre_index, self.song_index)

    def _move_genre_option(self, direction):
        # Convert the fake header option (-1) into normal modulo navigation by
        # shifting it up to zero before wrapping.
        option_index = (self.genre_index + 1 + direction) % self._genre_option_count()
        self.genre_index = option_index - 1

        # Highlighting a real genre immediately chooses the preview song that
        # will be highlighted if the player opens that genre.
        if self.genre_index != self.RANDOM_GENRE_INDEX:
            self.song_index = self._randomize_preview_song_index(self.genre_index)

    def _select_genre_option(self):
        if self.genre_index == self.RANDOM_GENRE_INDEX:
            # Pressing action on the header keeps the currently previewing
            # random song instead of choosing a new one.
            self._select_random_song()
            return

        self.stage = "song"
        self.song_index = self._preview_song_index(self.genre_index)
        self._post_update()

    def _genre_option_count(self):
        return len(self.genres) + 1

    def _song_option_count(self):
        return len(self._current_songs()) + 1

    def _back_selected(self):
        return self.stage == "song" and self.song_index == len(self._current_songs())

    def _back_to_genres(self):
        self.stage = "genre"
        self.song_index = self._preview_song_index(self.genre_index)
        self._post_update()

    def _preview_ended(self, **kwargs):
        del kwargs
        if not self.genres or self.stage == "confirmed":
            return

        if self.stage == "genre" and self.genre_index == self.RANDOM_GENRE_INDEX:
            self._advance_random_song()
        else:
            self.song_index = self._advance_preview_song(self.genre_index)

        self._post_update()

    # Song confirmation and player state.
    def _select_random_song(self):
        genre_index, song_index = self._random_selection()
        self.genre_index = genre_index
        self.song_index = song_index
        self._confirm_song(genre_index, song_index, random_selected=True)

    def _confirm_song(self, genre_index, song_index, random_selected=False):
        genre = self.genres[genre_index]
        song = genre["songs"][song_index]
        self._store_selected_song(genre, song)
        self.machine.events.post(
            "song_select_confirmed",
            **self._confirmed_song_payload(genre, song, random_selected),
        )
        self.stage = "confirmed"
        self.delay.add(ms=250, callback=self._complete_selection, name="song_select_complete")

    def _store_selected_song(self, genre, song):
        # Rhythm mode reads these player variables to pause the preview song,
        # play rhythm audio, then resume the selected song afterward.
        self.player.selected_song_genre = genre["name"]
        self.player.selected_song_title = song["title"]
        self.player.selected_song_key = song["sound_key"]
        self.player.selected_song_path = song.get("audio_path", "")
        self.player.selected_song_bus = self.song_bus
        self.player.selected_song_start_at = self.song_start_at
        self.player.selected_song_resume_at = self.song_start_at

    def _complete_selection(self):
        self.machine.events.post("song_select_complete")

    # Event payloads for the Godot slide.
    def _post_update(self):
        if not self.genres:
            return

        if self.stage == "genre" and self.genre_index == self.RANDOM_GENRE_INDEX:
            # The header selection still sends audio data so a random song can
            # begin playing before the player confirms it.
            self.machine.events.post("song_select_updated", **self._random_payload())
            return

        genre = self.genres[self.genre_index]
        if self.stage == "genre":
            self.song_index = self._preview_song_index(self.genre_index)
        elif self._back_selected():
            # The back row is visual-only, so it sends no playable audio.
            self.machine.events.post("song_select_updated", **self._back_payload(genre))
            return

        song = self._current_song()
        self.machine.events.post("song_select_updated", **self._selection_payload(genre, song))

    def _random_payload(self):
        genre_index, song_index = self._random_selection()
        genre = self.genres[genre_index]
        song = genre["songs"][song_index]
        payload = self._audio_payload(song)
        payload.update({
            "stage": self.stage,
            "genres": self._genre_names(),
            "selected_genre_index": self.RANDOM_GENRE_INDEX,
            "song_index": song_index + 1,
            "songs_text": "",
            "random_selected": True,
        })
        return payload

    def _selection_payload(self, genre, song):
        # Browsing payloads include only the display state and audio preview
        # fields the Godot slide actually needs.
        payload = self._audio_payload(song)
        payload.update({
            "stage": self.stage,
            "genres": self._genre_names(),
            "selected_genre_index": self.genre_index,
            "song_index": self.song_index + 1,
            "songs_text": self._songs_text(genre["songs"]),
            "random_selected": False,
        })
        return payload

    def _back_payload(self, genre):
        return {
            "stage": self.stage,
            "genres": self._genre_names(),
            "selected_genre_index": self.genre_index,
            "song_index": self.song_index + 1,
            "songs_text": self._songs_text(genre["songs"]),
            "sound_key": "",
            "audio_path": "",
            "song_bus": self.song_bus,
            "song_start_at": self.song_start_at,
            "has_audio": False,
            "random_selected": False,
        }

    def _confirmed_song_payload(self, genre, song, random_selected=False):
        # Confirmation keeps readable metadata for logs and any future scoring
        # or display code that wants to know the final choice.
        payload = self._audio_payload(song)
        payload.update({
            "genre": genre["name"],
            "song_title": song["title"],
            "random_selected": bool(random_selected),
        })
        return payload

    def _audio_payload(self, song):
        return {
            "sound_key": song["sound_key"],
            "audio_path": song.get("audio_path", ""),
            "song_bus": self.song_bus,
            "song_start_at": self.song_start_at,
            "has_audio": bool(song["has_audio"]),
        }

    def _genre_names(self):
        return [entry["name"] for entry in self.genres]

    # Current selection helpers and song list text.
    def _current_songs(self):
        return self.genres[self.genre_index]["songs"]

    def _current_song(self):
        songs = self._current_songs()
        return songs[self.song_index % len(songs)]

    def _random_selection(self):
        if self.random_genre_index is None or self.random_song_index is None:
            return self._randomize_random_selection()
        return self.random_genre_index, self.random_song_index

    def _randomize_random_selection(self):
        if not self.genres:
            self.random_genre_index = None
            self.random_song_index = None
            return None, None

        self.random_genre_index = random.randrange(len(self.genres))
        self.random_song_index = random.randrange(len(self.genres[self.random_genre_index]["songs"]))
        return self.random_genre_index, self.random_song_index

    def _advance_random_song(self):
        genre_index, song_index = self._random_selection()
        if genre_index is None:
            return

        self.random_song_index = self._next_playable_song_index(genre_index, song_index)

    def _preview_song_index(self, genre_index):
        if genre_index not in self.genre_preview_song_indices:
            return self._randomize_preview_song_index(genre_index)
        return self.genre_preview_song_indices[genre_index]

    def _randomize_preview_song_index(self, genre_index):
        song_index = random.randrange(len(self.genres[genre_index]["songs"]))
        self.genre_preview_song_indices[genre_index] = song_index
        return song_index

    def _advance_preview_song(self, genre_index):
        # Natural song endings should keep the player in the same genre and
        # move the highlight to the next playable song, skipping the Back row.
        current_index = self._preview_song_index(genre_index) if self._back_selected() else self.song_index
        song_index = self._next_playable_song_index(genre_index, current_index)
        self.genre_preview_song_indices[genre_index] = song_index
        return song_index

    def _next_playable_song_index(self, genre_index, current_index):
        songs = self.genres[genre_index]["songs"]
        for offset in range(1, len(songs) + 1):
            candidate_index = (current_index + offset) % len(songs)
            if songs[candidate_index]["has_audio"]:
                return candidate_index
        return current_index

    def _songs_text(self, songs):
        song_lines = [
            self._song_line(songs[index])
            for index in range(len(songs))
        ]
        song_lines.append(self.BACK_LABEL)
        return "\n".join(song_lines)

    def _song_line(self, song):
        suffix = "" if song["has_audio"] else " *"
        return "%s%s" % (song["title"], suffix)
