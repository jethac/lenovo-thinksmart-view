"""Texts for the wake phrase and its near misses, shared by the generators."""

# Spellings of the wake phrase for an English front end (all say the same thing).
POS_EN = [
    "hey straylight", "hey, straylight", "hey straylight!", "hey straylight?",
    "Hey Straylight.", "Hey, Straylight!", "hey stray light", "hey, stray-light",
]

# Magpie: (language mode, text). ja/zh modes give Japanese- and
# Mandarin-accented renderings.
POS_MAGPIE = [
    ("en", "Hey Straylight."), ("en", "Hey, Straylight!"), ("en", "Hey Straylight?"),
    ("en", "Hey, Straylight."),
    ("ja", "ヘイ、ストレイライト。"), ("ja", "ヘイ ストレイライト！"), ("ja", "へい、すとれいらいと。"),
    ("ja", "ヘイ、ストレイライト？"),
    ("zh", "Hey Straylight."), ("zh", "嘿，斯特雷莱特。"), ("zh", "嘿，Straylight。"),
    ("zh", "嘿，斯特雷莱特！"),
]

# Near misses: parts of the phrase, other assistants' wake words, and
# phrases that share most of its sounds. "stray light" on its own is the
# same sound as "Straylight" on its own, so both are here as "the second
# word without hey".
NEG_EN = [
    "hey", "hey!", "hey there", "hey you", "hey, how are you", "hey, wait",
    "straylight", "stray light", "the straylight", "a stray light", "straylight is on",
    "turn off the stray light", "Straylight, what time is it",
    "hey Siri", "hey Google", "okay Google", "Alexa", "hey Alexa", "hey Cortana", "hey Bixby",
    "hey starlight", "hey stray", "hey daylight", "hey skylight", "hey spotlight",
    "hey highlight", "hey satellite", "hey, it's late", "hey, stay right", "hey straight",
    "hey Dwight", "hey Mike", "hey stranger", "hey, try it", "hey, Stella",
    "stay right there", "satellite", "starlight", "daylight", "highlight", "street light",
    "hey Strava", "hey, straw", "okay, light", "hey, play right",
]

NEG_MAGPIE = [
    ("en", "Hey."), ("en", "Hey there!"), ("en", "Straylight."), ("en", "Stray light."),
    ("en", "Hey Siri."), ("en", "Hey Google."), ("en", "Alexa."), ("en", "Hey Starlight."),
    ("en", "Hey, stay right."), ("en", "Hey daylight."), ("en", "Hey skylight."), ("en", "Satellite."),
    ("en", "Okay Google."), ("en", "Hey, it's late."),
    ("ja", "ヘイ。"), ("ja", "ストレイライト。"), ("ja", "ヘイ、シリ。"), ("ja", "オーケー、グーグル。"),
    ("ja", "アレクサ。"), ("ja", "ヘイ、スターライト。"), ("ja", "ねえ、ちょっと。"), ("ja", "ヘイ、ストレート。"),
    ("zh", "嘿。"), ("zh", "斯特雷莱特。"), ("zh", "嘿，Siri。"), ("zh", "小爱同学。"), ("zh", "嘿，星光。"),
    ("zh", "你好，Google。"), ("zh", "嘿，斯塔莱特。"),
]
