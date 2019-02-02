import bpy

prop = bpy.context.preferences.addons["cycles"].preferences
prop.get_devices()
prop.compute_device_type = "CUDA"

for device in prop.devices:
    if device.type == "CUDA":
        device.use = True
bpy.context.scene.cycles.device = "GPU"

for scene in bpy.data.scenes:
    scene.cycles.device = "GPU" 
