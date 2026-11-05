"""Parity prompts. The system strings are the model card's documented prompt contract (not Phonon code)."""
BASE = ("Rewrite the raw dictation transcript into the exact text the speaker intended. Fix recognition errors and "
        "technical terms, keep the speaker's wording and casing style, do not add or drop content.")
MODES = {
    "minimal": "Writing mode: minimal (notes and documents).",
    "casual": "Writing mode: casual (a chat message).",
    "formal": "Writing mode: formal (an email or document).",
    "prompt": "Writing mode: prompt (an instruction to an AI assistant).",
}

def system(mode, vocab=None):
    s = BASE + "\n" + MODES[mode]
    if vocab:
        s += "\nVocabulary the speaker may use: " + ", ".join(vocab)
    return s

LONG = ("so um what i want to do is uh refactor the the cleanup post processor so that it takes the app context and "
        "the vocabulary and also the writing mode and then like it builds the the prompt in one place " * 6).strip()

CASES = [
    ("minimal_vocab", system("minimal", ["Muesli", "Parakeet", "LFM"]), "um so we should ship the muesli build to the the testers on tuesday actually no thursday"),
    ("casual", system("casual"), "hey are you coming to the thing tonight i i think its at eight"),
    ("formal_vocab", system("formal", ["Phonon", "Acme Corp"]), "hi sam thanks for the update on the acme corp contract i will review it by friday best regards jordan"),
    ("prompt_vocab", system("prompt", ["SwiftUI", "mlx-swift-lm"]), "add a swift ui view that shows the the model download progress using mlx swift lm and dont change the existing tests"),
    ("long_sliding", system("minimal", ["Muesli"]), LONG),
]
