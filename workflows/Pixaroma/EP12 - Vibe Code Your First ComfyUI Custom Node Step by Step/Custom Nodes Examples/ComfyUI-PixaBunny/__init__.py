from .pixa_frame import PixaFrame

# This tells ComfyUI to load your class
NODE_CLASS_MAPPINGS = {
    "PixaFrame": PixaFrame
}

# This sets the name that will appear in the ComfyUI menu
NODE_DISPLAY_NAME_MAPPINGS = {
    "PixaFrame": "PixaFrame"
}

__all__ = ['NODE_CLASS_MAPPINGS', 'NODE_DISPLAY_NAME_MAPPINGS']