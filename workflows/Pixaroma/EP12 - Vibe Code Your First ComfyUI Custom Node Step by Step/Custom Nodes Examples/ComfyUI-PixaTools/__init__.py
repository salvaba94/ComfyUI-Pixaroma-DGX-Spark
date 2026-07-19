from .pixa_cool_frames import PixaCoolFrames

NODE_CLASS_MAPPINGS = {
    "PixaCoolFrames": PixaCoolFrames,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "PixaCoolFrames": "PixaCoolFrames",
}

WEB_DIRECTORY = "./web"

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS", "WEB_DIRECTORY"]
