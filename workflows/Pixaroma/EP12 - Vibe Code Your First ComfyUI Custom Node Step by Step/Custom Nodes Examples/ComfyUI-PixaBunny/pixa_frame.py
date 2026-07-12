import torch

class PixaFrame:
    @classmethod
    def INPUT_TYPES(s):
        return {
            "required": {
                "image": ("IMAGE",),
                "frame_thickness": ("INT", {"default": 20, "min": 1, "max": 1000, "step": 1}),
                "red": ("INT", {"default": 255, "min": 0, "max": 255, "step": 1}),
                "green": ("INT", {"default": 255, "min": 0, "max": 255, "step": 1}),
                "blue": ("INT", {"default": 255, "min": 0, "max": 255, "step": 1}),
            },
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "add_frame"
    CATEGORY = "PixaBunny"

    def add_frame(self, image, frame_thickness, red, green, blue):
        # ComfyUI images are tensors with shape [Batch, Height, Width, Channels]
        batch_size, height, width, channels = image.shape
        
        # Convert RGB values (0-255) to ComfyUI's format (0.0-1.0)
        r = red / 255.0
        g = green / 255.0
        b = blue / 255.0
        
        if channels == 4: # If the image has an Alpha (transparency) channel
            color_tensor = torch.tensor([r, g, b, 1.0])
        else:
            color_tensor = torch.tensor([r, g, b])
        
        # Calculate the new dimensions of the image including the frame
        new_height = height + (frame_thickness * 2)
        new_width = width + (frame_thickness * 2)
        
        # Create a blank canvas filled with your chosen frame color
        framed_image = torch.zeros((batch_size, new_height, new_width, channels), dtype=image.dtype, device=image.device)
        framed_image[:, :, :] = color_tensor
        
        # Paste the original image right into the center of the frame
        framed_image[:, frame_thickness:frame_thickness+height, frame_thickness:frame_thickness+width, :] = image
        
        return (framed_image,)