# Voice Memo App Documentation

## Overview

This is a simple voice memo app for iOS. It allows users to record, play, import, and manage voice memos.

## Features

- Record new voice memos.
- Import audio files as voice memos.
- Play back voice memos with a slider for scrubbing.
- Rename and delete voice memos.
- Persistently store voice memos.

## Code Structure

The project is structured using the MVVM (Model-View-ViewModel) design pattern.

- **Models:** Contains the data structures of the app.
  - `VoiceMemo.swift`: Defines the `VoiceMemo` model.
- **ViewModels:** Contains the business logic and data management for the views.
  - `VoiceMemoViewModel.swift`: Manages the voice memos, recording, playback, and storage.
- **Views:** Contains the UI of the app.
  - `ContentView.swift`: The main view of the app, displaying the list of voice memos and controls for recording and importing.
  - `PlaybackView.swift`: The view for playing back a voice memo, with controls for play/pause and scrubbing.

## Data Model

### `VoiceMemo`

A struct that represents a single voice memo.

- `id`: A unique identifier for the memo.
- `title`: The title of the memo.
- `date`: The date the memo was created.
- `url`: The URL of the audio file.

## View Model

### `VoiceMemoViewModel`

An `ObservableObject` that manages the voice memos.

- `@Published var voiceMemos`: An array of `VoiceMemo` objects that represents the list of memos.
- `@Published var isRecording`: A boolean that indicates whether a recording is in progress.
- `@Published var isPlaying`: A boolean that indicates whether a memo is currently playing.
- `@Published var currentMemo`: The memo that is currently being played.

#### Functions

- `startRecording()`: Starts a new audio recording.
- `stopRecording()`: Stops the current audio recording and saves it as a new memo.
- `startPlayback(memo: VoiceMemo)`: Starts playing the specified memo.
- `stopPlayback()`: Stops the current playback.
- `createPlayback(memo: VoiceMemo) -> AVAudioPlayer?`: Creates an `AVAudioPlayer` instance for the specified memo.
- `deleteMemo(at offsets: IndexSet)`: Deletes the memos at the specified offsets.
- `renameMemo(memo: VoiceMemo, newTitle: String)`: Renames the specified memo.
- `importAudio(url: URL)`: Imports an audio file from the given URL and saves it as a new memo.

## Views

### `ContentView`

The main view of the app.

- Displays a list of all the voice memos.
- Each memo in the list is a `NavigationLink` to the `PlaybackView`.
- Provides a button to start and stop recording.
- Provides a button to import an audio file.
- Allows users to delete memos by swiping on the list items.
- Allows users to rename memos using a context menu.

### `PlaybackView`

The view for playing back a voice memo.

- Displays the title and date of the memo.
- Provides a slider to scrub through the audio.
- Displays the current time and total duration of the audio.
- Provides a play/pause button.
- Allows users to rename the memo by tapping on the title.
