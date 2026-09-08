#!/bin/sh
# Builds spoken test clips with the macOS `say` command. Each clip gets a .txt with the words spoken.
# [[slnc N]] inserts N ms of silence, which lets a clip put pauses exactly where a test needs them.
set -e
out="${1:-Tests/fixtures}"
voice="${VOICE:-Samantha}"
mkdir -p "$out"

make_clip() {
    name="$1"
    spoken="$2"
    reference="$3"
    aiff="$out/$name.aiff"
    say -v "$voice" -o "$aiff" "$spoken"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$out/$name.wav"
    rm -f "$aiff"
    printf '%s\n' "$reference" > "$out/$name.txt"
    echo "made $out/$name.wav"
}

# Clean sentence breaks with clear pauses.
make_clip sentences \
    "The meeting starts at nine tomorrow. [[slnc 700]] Please bring the printed report. [[slnc 700]] We will review the budget first." \
    "The meeting starts at nine tomorrow. Please bring the printed report. We will review the budget first."

# A pause in the middle of a sentence. The words must stay together and not gain a period.
make_clip midpause \
    "I wanted to ask whether [[slnc 900]] the new schedule works for the whole team. [[slnc 600]] Let me know by Friday." \
    "I wanted to ask whether the new schedule works for the whole team. Let me know by Friday."

# Sentences spoken quickly with no extra pauses.
make_clip nopause \
    "First we load the data. Then we clean the columns. After that we train the model. Finally we check the results." \
    "First we load the data. Then we clean the columns. After that we train the model. Finally we check the results."

# Long run of speech with only commas, to force the window cap.
long_text="We started the trip early in the morning, packed the car with food and water, drove along the coast for several hours, stopped at a small town for coffee, walked through the market by the harbor, bought fresh bread and fruit, continued through the hills past the old farms, watched the clouds gather over the mountains, arrived at the cabin before dark, unloaded everything into the kitchen, lit the stove to warm the rooms, and sat on the porch listening to the rain while the dog slept by the door and the kettle slowly came to a boil"
make_clip long "$long_text" "$long_text"

# Speech, a long pause, then more speech without punctuation before the pause.
make_clip stopstart \
    "Remind me to call the bank about the new card [[slnc 2000]] and also order more paper for the printer." \
    "Remind me to call the bank about the new card and also order more paper for the printer."
