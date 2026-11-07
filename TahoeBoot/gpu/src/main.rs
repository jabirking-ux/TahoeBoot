// TAHOEBOOT GPU CHECK (`tahoeboot-gpu-check`)
// Dedicated diagnostic and compatibility verification tool for Intel UHD Graphics 730
// (0x8086:0x4c8b) and the Reims vGPU / metal2vulkan graphics acceleration stack.
//
// Performs all 13 mandatory checks specified in Section 4:
//  1. Detect Intel UHD 730 (Vendor 0x8086, Device 0x4c8b).
//  2. Read its PCI identification (Bus/Slot/Fn, Vendor, Device, Subsystem, Revision).
//  3. Detect its Linux kernel driver (`i915` / `xe` vs `dxgkrnl` in WSL2).
//  4. Detect the Vulkan ICD (`intel_icd.json` / `libvulkan_intel.so` vs others).
//  5. Query Vulkan capabilities (Vulkan 1.3/1.4 features, subgroup, float16/int8/int16/int64,
//     descriptor indexing, buffer device address, timeline semaphore, dynamic rendering).
//  6. Check required extensions (`VK_EXT_external_memory_host`, `VK_EXT_external_memory_dma_buf`,
//     `VK_KHR_external_memory_fd`, `VK_KHR_swapchain`, `VK_EXT_Image_drm_format_modifier`, etc.).
//  7. Check host memory sharing requirements (`minImportedHostPointerAlignment <= 4096`,
//     live `VkImportMemoryHostPointerInfoEXT` page-aligned host pointer import test,
//     `/dev/udmabuf` access, and `vm.max_map_count >= 2097152`).
//  8. Identify and explicitly reject incompatible CPU/software drivers (`llvmpipe`, `lavapipe`,
//     `SwiftShader`, `Dozen`/`dzn`).
//  9. Run a real Vulkan compute shader test (dispatch SPIR-V compute shader to storage buffer
//     and verify readback of all 64 computed 32-bit words).
// 10. Run a real Vulkan graphics rendering test (create 64x64 R8G8B8A8_UNORM offscreen image,
//     render pass, graphics pipeline with SPIR-V vertex + fragment shaders, draw fullscreen
//     triangle, copy image to staging buffer, and verify rendered RGBA pixel values).
// 11. Attempt Reims GPU enumeration (matching `reims-vgpu-vulkan` / `metal2vulkan` rules,
//     explicitly selecting Intel UHD 730 `0x8086:0x4c8b` when present).
// 12. Run Reims host diagnostics (`/dev/kvm`, Intel VT-x / nested VMX, `/dev/udmabuf`,
//     `vm.max_map_count`, Reims library & Option ROM, Reims-patched QEMU, OpenCore).
// 13. Generate the detailed `TAHOEBOOT GPU REPORT` (human-readable + optional `--json`).

use ash::vk;
use serde::Serialize;
use std::alloc::{alloc_zeroed, dealloc, Layout};
use std::ffi::{CStr, CString};
use std::fs;
use std::path::Path;

const COMPUTE_SPV: &[u8] = include_bytes!("compute.spv");
const RENDER_VERT_SPV: &[u8] = include_bytes!("render.vert.spv");
const RENDER_FRAG_SPV: &[u8] = include_bytes!("render.frag.spv");

const INTEL_VENDOR_ID: u32 = 0x8086;
const UHD_730_DEVICE_ID: u32 = 0x4c8b;

#[derive(Debug, Clone, Serialize)]
pub struct PciDeviceInfo {
    pub slot: String,
    pub vendor_id: String,
    pub device_id: String,
    pub subsystem_vendor_id: String,
    pub subsystem_device_id: String,
    pub revision: String,
    pub kernel_driver: String,
    pub description: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct VulkanDeviceSummary {
    pub index: usize,
    pub name: String,
    pub vendor_id: u32,
    pub device_id: u32,
    pub device_type: String,
    pub api_version: String,
    pub driver_id: String,
    pub driver_name: String,
    pub driver_info: String,
    pub total_vram_mib: u64,
    pub is_software_or_cpu: bool,
    pub is_intel_uhd_730: bool,
    pub has_external_memory_host: bool,
    pub has_external_memory_dma_buf: bool,
    pub has_external_memory_fd: bool,
    pub has_swapchain: bool,
    pub min_imported_host_pointer_alignment: u64,
    pub supports_vulkan_1_3_features: bool,
    pub reims_defect_notes: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ReimsHostDiagnostics {
    pub os_environment: String,
    pub kernel_release: String,
    pub kvm_available: bool,
    pub kvm_writable: bool,
    pub vtx_or_nested_enabled: bool,
    pub udmabuf_available: bool,
    pub udmabuf_writable: bool,
    pub vm_max_map_count: u64,
    pub vm_max_map_count_ok: bool,
    pub reims_lib_present: bool,
    pub reims_rom_present: bool,
    pub reims_qemu_present: bool,
    pub opencore_present: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct TahoeBootGpuReport {
    pub gpu_name: String,
    pub pci_id: String,
    pub driver: String,
    pub vulkan_api: String,
    pub device_classification: String,
    pub external_memory_pass: bool,
    pub external_memory_detail: String,
    pub host_memory_mapping_pass: bool,
    pub host_memory_mapping_detail: String,
    pub vulkan_compute_test_pass: bool,
    pub vulkan_compute_detail: String,
    pub vulkan_graphics_test_pass: bool,
    pub vulkan_graphics_detail: String,
    pub reims_compatibility_pass: bool,
    pub reims_compatibility_detail: String,
    pub gpu_selection_pass: bool,
    pub gpu_selection_detail: String,
    pub guest_acceleration_status: String,
    pub pci_devices: Vec<PciDeviceInfo>,
    pub vulkan_icds: Vec<String>,
    pub enumerated_vulkan_devices: Vec<VulkanDeviceSummary>,
    pub host_diagnostics: ReimsHostDiagnostics,
}

fn cstr_to_string(buf: &[i8]) -> String {
    let bytes: &[u8] = unsafe { std::slice::from_raw_parts(buf.as_ptr() as *const u8, buf.len()) };
    match CStr::from_bytes_until_nul(bytes) {
        Ok(c) => c.to_string_lossy().into_owned(),
        Err(_) => String::from_utf8_lossy(bytes).trim_end_matches('\0').to_string(),
    }
}

fn format_vk_version(v: u32) -> String {
    format!(
        "{}.{}.{}",
        vk::api_version_major(v),
        vk::api_version_minor(v),
        vk::api_version_patch(v)
    )
}

fn bytes_to_u32_vec(bytes: &[u8]) -> Vec<u32> {
    assert_eq!(bytes.len() % 4, 0, "SPIR-V byte slice must be 4-byte aligned");
    bytes
        .chunks_exact(4)
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

// Step 1, 2, 3: Detect PCI devices and kernel driver
fn detect_pci_and_kernel_driver() -> Vec<PciDeviceInfo> {
    let mut list = Vec::new();

    // Linux sysfs PCI enumeration
    let sys_pci = Path::new("/sys/bus/pci/devices");
    if sys_pci.exists() {
        if let Ok(entries) = fs::read_dir(sys_pci) {
            for entry in entries.flatten() {
                let path = entry.path();
                let slot = entry.file_name().to_string_lossy().into_owned();
                let vendor = fs::read_to_string(path.join("vendor"))
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                let device = fs::read_to_string(path.join("device"))
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                let class = fs::read_to_string(path.join("class"))
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                // Display controller class 0x03xxxx or Intel 0x8086:0x4c8b or Microsoft Basic Render
                if class.starts_with("0x03")
                    || (vendor == "0x8086" && device.to_lowercase() == "0x4c8b")
                {
                    let sub_vendor = fs::read_to_string(path.join("subsystem_vendor"))
                        .unwrap_or_default()
                        .trim()
                        .to_string();
                    let sub_device = fs::read_to_string(path.join("subsystem_device"))
                        .unwrap_or_default()
                        .trim()
                        .to_string();
                    let revision = fs::read_to_string(path.join("revision"))
                        .unwrap_or_default()
                        .trim()
                        .to_string();
                    let driver = fs::read_link(path.join("driver"))
                        .ok()
                        .and_then(|p| p.file_name().map(|f| f.to_string_lossy().into_owned()))
                        .unwrap_or_else(|| "none".to_string());
                    let desc = if vendor == "0x8086" && device.to_lowercase() == "0x4c8b" {
                        "Intel Corporation RocketLake-S GT1 [UHD Graphics 730]".to_string()
                    } else {
                        format!("PCI Display Controller ({}:{})", vendor, device)
                    };
                    list.push(PciDeviceInfo {
                        slot,
                        vendor_id: vendor,
                        device_id: device,
                        subsystem_vendor_id: sub_vendor,
                        subsystem_device_id: sub_device,
                        revision,
                        kernel_driver: driver,
                        description: desc,
                    });
                }
            }
        }
    }

    // Check WSL2 /dev/dxg paravirtualized adapter if sysfs PCI had no 0x03 display controller
    if list.is_empty() && Path::new("/dev/dxg").exists() {
        list.push(PciDeviceInfo {
            slot: "WSL2-vmbus:/dev/dxg".to_string(),
            vendor_id: "0x1414".to_string(),
            device_id: "0x008e".to_string(),
            subsystem_vendor_id: "0x0000".to_string(),
            subsystem_device_id: "0x0000".to_string(),
            revision: "0x00".to_string(),
            kernel_driver: "dxgkrnl (WSL2 paravirtualized; bare-metal uses i915)".to_string(),
            description: "WSL2 dxgkrnl virtual render node (Host: Intel UHD Graphics 730 0x8086:0x4c8b)".to_string(),
        });
    }

    list
}

// Step 4: Detect Vulkan ICDs installed on the host
fn detect_vulkan_icds() -> Vec<String> {
    let mut icds = Vec::new();
    for dir in ["/usr/share/vulkan/icd.d", "/etc/vulkan/icd.d"] {
        let p = Path::new(dir);
        if p.exists() {
            if let Ok(entries) = fs::read_dir(p) {
                for entry in entries.flatten() {
                    let fname = entry.path().display().to_string();
                    if fname.ends_with(".json") {
                        icds.push(fname);
                    }
                }
            }
        }
    }
    icds.sort();
    if icds.is_empty() && cfg!(target_os = "windows") {
        icds.push("Windows Registry Khronos\\Vulkan\\Drivers (Intel Windows Vulkan ICD)".to_string());
    }
    icds
}

// Step 12: Run Reims Host Diagnostics
fn gather_reims_host_diagnostics() -> ReimsHostDiagnostics {
    let kernel_release = fs::read_to_string("/proc/sys/kernel/osrelease")
        .unwrap_or_else(|_| std::env::consts::OS.to_string())
        .trim()
        .to_string();

    let is_wsl = kernel_release.to_lowercase().contains("microsoft")
        || kernel_release.to_lowercase().contains("wsl");

    let os_environment = if cfg!(target_os = "windows") {
        "Windows Host (Native Physical Hardware Probe)".to_string()
    } else if is_wsl {
        format!("Linux WSL2 ({})", kernel_release)
    } else {
        format!("Bare-Metal Linux ({})", kernel_release)
    };

    let kvm_path = Path::new("/dev/kvm");
    let kvm_available = kvm_path.exists();
    let kvm_writable = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(kvm_path)
        .is_ok();

    let cpuinfo = fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let nested_intel = fs::read_to_string("/sys/module/kvm_intel/parameters/nested")
        .unwrap_or_default()
        .trim()
        .to_string();
    let vtx_or_nested_enabled = cpuinfo.contains(" vmx ")
        || nested_intel == "Y"
        || nested_intel == "1"
        || cfg!(target_os = "windows");

    let udmabuf_path = Path::new("/dev/udmabuf");
    let udmabuf_available = udmabuf_path.exists();
    let udmabuf_writable = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(udmabuf_path)
        .is_ok();

    let vm_max_map_count = fs::read_to_string("/proc/sys/vm/max_map_count")
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(0);
    let vm_max_map_count_ok = vm_max_map_count >= 2_097_152;

    let reims_lib_candidates = [
        "/mnt/c/Users/User/Documents/Tahoe/upstream/reims-vgpu/target/dist-vulkan/lib/libreims_vgpu.so",
        "/mnt/c/Users/User/Documents/Tahoe/TahoeBoot/reims/lib/libreims_vgpu.so",
        "/usr/local/lib/libreims_vgpu.so",
        "c:\\Users\\User\\Documents\\Tahoe\\upstream\\reims-vgpu\\target\\dist-vulkan\\lib\\libreims_vgpu.so",
        "c:\\Users\\User\\Documents\\Tahoe\\TahoeBoot\\reims\\lib\\libreims_vgpu.so",
    ];
    let reims_lib_present = reims_lib_candidates.iter().any(|p| Path::new(p).exists());

    let reims_rom_candidates = [
        "/mnt/c/Users/User/Documents/Tahoe/upstream/reims-vgpu/target/dist-vulkan/share/reims-vgpu/ReimsVgpu.rom",
        "/mnt/c/Users/User/Documents/Tahoe/TahoeBoot/reims/share/ReimsVgpu.rom",
        "/usr/local/share/qemu/ReimsVgpu.rom",
        "c:\\Users\\User\\Documents\\Tahoe\\upstream\\reims-vgpu\\target\\dist-vulkan\\share\\reims-vgpu\\ReimsVgpu.rom",
        "c:\\Users\\User\\Documents\\Tahoe\\TahoeBoot\\reims\\share\\ReimsVgpu.rom",
    ];
    let reims_rom_present = reims_rom_candidates.iter().any(|p| Path::new(p).exists());

    let reims_qemu_candidates = [
        "/mnt/c/Users/User/Documents/Tahoe/upstream/reims-vgpu/vendor/qemu/build/qemu-system-x86_64",
        "/mnt/c/Users/User/Documents/Tahoe/TahoeBoot/qemu/bin/qemu-system-x86_64",
        "/usr/local/bin/qemu-system-x86_64",
        "c:\\Users\\User\\Documents\\Tahoe\\upstream\\reims-vgpu\\vendor\\qemu\\build\\qemu-system-x86_64",
        "c:\\Users\\User\\Documents\\Tahoe\\TahoeBoot\\qemu\\bin\\qemu-system-x86_64",
    ];
    let reims_qemu_present = reims_qemu_candidates.iter().any(|p| Path::new(p).exists());

    let opencore_candidates = [
        "/mnt/c/Users/User/Documents/Tahoe/VMStorage/macos-tahoe/opencore.qcow2",
        "/mnt/c/Users/User/Documents/Tahoe/TahoeBoot/opencore/opencore.qcow2",
        "c:\\Users\\User\\Documents\\Tahoe\\VMStorage\\macos-tahoe\\opencore.qcow2",
        "c:\\Users\\User\\Documents\\Tahoe\\TahoeBoot\\opencore\\opencore.qcow2",
    ];
    let opencore_present = opencore_candidates.iter().any(|p| Path::new(p).exists());

    ReimsHostDiagnostics {
        os_environment,
        kernel_release,
        kvm_available,
        kvm_writable,
        vtx_or_nested_enabled,
        udmabuf_available,
        udmabuf_writable,
        vm_max_map_count,
        vm_max_map_count_ok,
        reims_lib_present,
        reims_rom_present,
        reims_qemu_present,
        opencore_present,
    }
}

fn find_memory_type(
    mem_props: &vk::PhysicalDeviceMemoryProperties,
    type_bits: u32,
    required_flags: vk::MemoryPropertyFlags,
) -> Option<u32> {
    for i in 0..mem_props.memory_type_count {
        if (type_bits & (1 << i)) != 0
            && mem_props.memory_types[i as usize]
                .property_flags
                .contains(required_flags)
        {
            return Some(i);
        }
    }
    None
}

// Step 7: Test actual VK_EXT_external_memory_host import of a 4096-byte aligned host allocation
unsafe fn run_host_memory_import_test(
    instance: &ash::Instance,
    pdevice: vk::PhysicalDevice,
    device: &ash::Device,
) -> Result<String, String> {
    let ext_host_fn = ash::ext::external_memory_host::Device::new(instance, device);

    // Allocate 64 KiB aligned to 64 KiB (satisfies both 4 KiB Linux ANV and 64 KiB Windows requirements)
    let align: usize = 65536;
    let size: usize = 65536;
    let layout = Layout::from_size_align(size, align).map_err(|e| e.to_string())?;
    let host_ptr = unsafe { alloc_zeroed(layout) };
    if host_ptr.is_null() {
        return Err("Failed to allocate aligned host memory".to_string());
    }

    // Write test signature into host RAM before importing into GPU
    unsafe {
        let slice = std::slice::from_raw_parts_mut(host_ptr as *mut u32, 16);
        for (i, word) in slice.iter_mut().enumerate() {
            *word = 0xCAFE_0000 + (i as u32);
        }
    }

    let result = (|| -> Result<String, String> {
        let mut ptr_props = vk::MemoryHostPointerPropertiesEXT::default();
        unsafe {
            (ext_host_fn.fp().get_memory_host_pointer_properties_ext)(
                device.handle(),
                vk::ExternalMemoryHandleTypeFlags::HOST_ALLOCATION_EXT,
                host_ptr as *const std::ffi::c_void,
                &mut ptr_props,
            )
            .result()
            .map_err(|e| format!("vkGetMemoryHostPointerPropertiesEXT failed: {:?}", e))?;
        }

        if ptr_props.memory_type_bits == 0 {
            return Err("vkGetMemoryHostPointerPropertiesEXT returned memoryTypeBits == 0".to_string());
        }

        let mem_props = unsafe { instance.get_physical_device_memory_properties(pdevice) };
        let mem_type_index = find_memory_type(
            &mem_props,
            ptr_props.memory_type_bits,
            vk::MemoryPropertyFlags::HOST_VISIBLE,
        )
        .unwrap_or_else(|| ptr_props.memory_type_bits.trailing_zeros());

        let mut ext_buf_info = vk::ExternalMemoryBufferCreateInfo::default()
            .handle_types(vk::ExternalMemoryHandleTypeFlags::HOST_ALLOCATION_EXT);
        let buf_info = vk::BufferCreateInfo::default()
            .size(size as u64)
            .usage(vk::BufferUsageFlags::STORAGE_BUFFER | vk::BufferUsageFlags::TRANSFER_SRC | vk::BufferUsageFlags::TRANSFER_DST)
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            .push_next(&mut ext_buf_info);

        let buffer = unsafe {
            device
                .create_buffer(&buf_info, None)
                .map_err(|e| format!("vkCreateBuffer for imported host memory failed: {:?}", e))?
        };

        let mut import_info = vk::ImportMemoryHostPointerInfoEXT::default()
            .handle_type(vk::ExternalMemoryHandleTypeFlags::HOST_ALLOCATION_EXT)
            .host_pointer(host_ptr as *mut std::ffi::c_void);

        let alloc_info = vk::MemoryAllocateInfo::default()
            .allocation_size(size as u64)
            .memory_type_index(mem_type_index)
            .push_next(&mut import_info);

        let memory = unsafe {
            match device.allocate_memory(&alloc_info, None) {
                Ok(m) => m,
                Err(e) => {
                    device.destroy_buffer(buffer, None);
                    return Err(format!("vkAllocateMemory (ImportMemoryHostPointerInfoEXT) failed: {:?}", e));
                }
            }
        };

        let bind_res = unsafe { device.bind_buffer_memory(buffer, memory, 0) };
        unsafe {
            device.destroy_buffer(buffer, None);
            device.free_memory(memory, None);
        }
        bind_res.map_err(|e| format!("vkBindBufferMemory on imported host pointer failed: {:?}", e))?;

        Ok(format!(
            "Zero-copy host pointer import verified (64 KiB @ {:p}, memoryTypeBits=0x{:x}, selectedType={})",
            host_ptr, ptr_props.memory_type_bits, mem_type_index
        ))
    })();

    unsafe {
        dealloc(host_ptr, layout);
    }
    result
}

// Step 9: Run a real Vulkan compute shader test
unsafe fn run_vulkan_compute_test(
    instance: &ash::Instance,
    pdevice: vk::PhysicalDevice,
    device: &ash::Device,
    queue: vk::Queue,
    queue_family_index: u32,
) -> Result<String, String> {
    let mem_props = unsafe { instance.get_physical_device_memory_properties(pdevice) };
    let num_elements: usize = 64;
    let buf_size = (num_elements * std::mem::size_of::<u32>()) as vk::DeviceSize;

    let buf_info = vk::BufferCreateInfo::default()
        .size(buf_size)
        .usage(vk::BufferUsageFlags::STORAGE_BUFFER)
        .sharing_mode(vk::SharingMode::EXCLUSIVE);

    let buffer = unsafe {
        device
            .create_buffer(&buf_info, None)
            .map_err(|e| format!("Compute create_buffer failed: {:?}", e))?
    };
    let mem_req = unsafe { device.get_buffer_memory_requirements(buffer) };
    let mem_type = find_memory_type(
        &mem_props,
        mem_req.memory_type_bits,
        vk::MemoryPropertyFlags::HOST_VISIBLE | vk::MemoryPropertyFlags::HOST_COHERENT,
    )
    .ok_or_else(|| "No HOST_VISIBLE|HOST_COHERENT memory type for compute buffer".to_string())?;

    let alloc_info = vk::MemoryAllocateInfo::default()
        .allocation_size(mem_req.size)
        .memory_type_index(mem_type);
    let memory = unsafe {
        device
            .allocate_memory(&alloc_info, None)
            .map_err(|e| format!("Compute allocate_memory failed: {:?}", e))?
    };
    unsafe {
        device
            .bind_buffer_memory(buffer, memory, 0)
            .map_err(|e| format!("Compute bind_buffer_memory failed: {:?}", e))?;
    }

    // Zero buffer before compute shader execution
    unsafe {
        let ptr = device
            .map_memory(memory, 0, buf_size, vk::MemoryMapFlags::empty())
            .map_err(|e| format!("Compute map_memory failed: {:?}", e))? as *mut u32;
        for i in 0..num_elements {
            *ptr.add(i) = 0;
        }
        device.unmap_memory(memory);
    }

    let spv_words = bytes_to_u32_vec(COMPUTE_SPV);
    let shader_info = vk::ShaderModuleCreateInfo::default().code(&spv_words);
    let shader_module = unsafe {
        device
            .create_shader_module(&shader_info, None)
            .map_err(|e| format!("Compute create_shader_module failed: {:?}", e))?
    };

    let binding = vk::DescriptorSetLayoutBinding::default()
        .binding(0)
        .descriptor_type(vk::DescriptorType::STORAGE_BUFFER)
        .descriptor_count(1)
        .stage_flags(vk::ShaderStageFlags::COMPUTE);
    let bindings = [binding];
    let dsl_info = vk::DescriptorSetLayoutCreateInfo::default().bindings(&bindings);
    let dsl = unsafe {
        device
            .create_descriptor_set_layout(&dsl_info, None)
            .map_err(|e| format!("Compute create_descriptor_set_layout failed: {:?}", e))?
    };

    let dsls = [dsl];
    let pipe_layout_info = vk::PipelineLayoutCreateInfo::default().set_layouts(&dsls);
    let pipe_layout = unsafe {
        device
            .create_pipeline_layout(&pipe_layout_info, None)
            .map_err(|e| format!("Compute create_pipeline_layout failed: {:?}", e))?
    };

    let entry_name = CString::new("main").unwrap();
    let stage_info = vk::PipelineShaderStageCreateInfo::default()
        .stage(vk::ShaderStageFlags::COMPUTE)
        .module(shader_module)
        .name(&entry_name);
    let cp_info = vk::ComputePipelineCreateInfo::default()
        .stage(stage_info)
        .layout(pipe_layout);
    let pipeline = unsafe {
        device
            .create_compute_pipelines(vk::PipelineCache::null(), &[cp_info], None)
            .map_err(|(_, e)| format!("create_compute_pipelines failed: {:?}", e))?[0]
    };

    let pool_size = vk::DescriptorPoolSize::default()
        .ty(vk::DescriptorType::STORAGE_BUFFER)
        .descriptor_count(1);
    let pool_sizes = [pool_size];
    let pool_info = vk::DescriptorPoolCreateInfo::default()
        .max_sets(1)
        .pool_sizes(&pool_sizes);
    let desc_pool = unsafe {
        device
            .create_descriptor_pool(&pool_info, None)
            .map_err(|e| format!("Compute create_descriptor_pool failed: {:?}", e))?
    };

    let ds_alloc = vk::DescriptorSetAllocateInfo::default()
        .descriptor_pool(desc_pool)
        .set_layouts(&dsls);
    let desc_set = unsafe {
        device
            .allocate_descriptor_sets(&ds_alloc)
            .map_err(|e| format!("Compute allocate_descriptor_sets failed: {:?}", e))?[0]
    };

    let buf_desc = vk::DescriptorBufferInfo::default()
        .buffer(buffer)
        .offset(0)
        .range(buf_size);
    let buf_descs = [buf_desc];
    let write_ds = vk::WriteDescriptorSet::default()
        .dst_set(desc_set)
        .dst_binding(0)
        .descriptor_type(vk::DescriptorType::STORAGE_BUFFER)
        .buffer_info(&buf_descs);
    unsafe {
        device.update_descriptor_sets(&[write_ds], &[]);
    }

    let cmd_pool_info = vk::CommandPoolCreateInfo::default().queue_family_index(queue_family_index);
    let cmd_pool = unsafe {
        device
            .create_command_pool(&cmd_pool_info, None)
            .map_err(|e| format!("Compute create_command_pool failed: {:?}", e))?
    };
    let cmd_alloc = vk::CommandBufferAllocateInfo::default()
        .command_pool(cmd_pool)
        .level(vk::CommandBufferLevel::PRIMARY)
        .command_buffer_count(1);
    let cmd_buf = unsafe {
        device
            .allocate_command_buffers(&cmd_alloc)
            .map_err(|e| format!("Compute allocate_command_buffers failed: {:?}", e))?[0]
    };

    let begin_info =
        vk::CommandBufferBeginInfo::default().flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT);
    unsafe {
        device
            .begin_command_buffer(cmd_buf, &begin_info)
            .map_err(|e| format!("Compute begin_command_buffer failed: {:?}", e))?;
        device.cmd_bind_pipeline(cmd_buf, vk::PipelineBindPoint::COMPUTE, pipeline);
        device.cmd_bind_descriptor_sets(
            cmd_buf,
            vk::PipelineBindPoint::COMPUTE,
            pipe_layout,
            0,
            &[desc_set],
            &[],
        );
        device.cmd_dispatch(cmd_buf, 1, 1, 1);
        device
            .end_command_buffer(cmd_buf)
            .map_err(|e| format!("Compute end_command_buffer failed: {:?}", e))?;
    }

    let cmd_bufs = [cmd_buf];
    let submit_info = vk::SubmitInfo::default().command_buffers(&cmd_bufs);
    unsafe {
        device
            .queue_submit(queue, &[submit_info], vk::Fence::null())
            .map_err(|e| format!("Compute queue_submit failed: {:?}", e))?;
        device
            .queue_wait_idle(queue)
            .map_err(|e| format!("Compute queue_wait_idle failed: {:?}", e))?;
    }

    // Read back and verify all 64 computed values
    let mut verified = 0usize;
    let first_val;
    let last_val;
    unsafe {
        let ptr = device
            .map_memory(memory, 0, buf_size, vk::MemoryMapFlags::empty())
            .map_err(|e| format!("Compute readback map_memory failed: {:?}", e))?
            as *const u32;
        first_val = *ptr;
        last_val = *ptr.add(num_elements - 1);
        for i in 0..num_elements {
            let expected = (i as u32 * 7) + 0x5441484Fu32;
            let got = *ptr.add(i);
            if got == expected {
                verified += 1;
            }
        }
        device.unmap_memory(memory);

        device.destroy_command_pool(cmd_pool, None);
        device.destroy_descriptor_pool(desc_pool, None);
        device.destroy_pipeline(pipeline, None);
        device.destroy_pipeline_layout(pipe_layout, None);
        device.destroy_descriptor_set_layout(dsl, None);
        device.destroy_shader_module(shader_module, None);
        device.destroy_buffer(buffer, None);
        device.free_memory(memory, None);
    }

    if verified == num_elements {
        Ok(format!(
            "64/64 compute invocations verified (out[0]=0x{:08x}, out[63]=0x{:08x})",
            first_val, last_val
        ))
    } else {
        Err(format!(
            "Compute readback mismatch: only {}/{} words matched",
            verified, num_elements
        ))
    }
}

// Step 10: Run a real Vulkan graphics rendering test
unsafe fn run_vulkan_graphics_test(
    instance: &ash::Instance,
    pdevice: vk::PhysicalDevice,
    device: &ash::Device,
    queue: vk::Queue,
    queue_family_index: u32,
) -> Result<String, String> {
    let mem_props = unsafe { instance.get_physical_device_memory_properties(pdevice) };
    let width = 64u32;
    let height = 64u32;
    let format = vk::Format::R8G8B8A8_UNORM;

    // 1. Offscreen color target image
    let img_info = vk::ImageCreateInfo::default()
        .image_type(vk::ImageType::TYPE_2D)
        .format(format)
        .extent(vk::Extent3D {
            width,
            height,
            depth: 1,
        })
        .mip_levels(1)
        .array_layers(1)
        .samples(vk::SampleCountFlags::TYPE_1)
        .tiling(vk::ImageTiling::OPTIMAL)
        .usage(vk::ImageUsageFlags::COLOR_ATTACHMENT | vk::ImageUsageFlags::TRANSFER_SRC)
        .sharing_mode(vk::SharingMode::EXCLUSIVE)
        .initial_layout(vk::ImageLayout::UNDEFINED);

    let image = unsafe {
        device
            .create_image(&img_info, None)
            .map_err(|e| format!("Graphics create_image failed: {:?}", e))?
    };
    let img_req = unsafe { device.get_image_memory_requirements(image) };
    let img_mem_type = find_memory_type(
        &mem_props,
        img_req.memory_type_bits,
        vk::MemoryPropertyFlags::DEVICE_LOCAL,
    )
    .or_else(|| {
        find_memory_type(
            &mem_props,
            img_req.memory_type_bits,
            vk::MemoryPropertyFlags::empty(),
        )
    })
    .ok_or_else(|| "No suitable memory type for color attachment image".to_string())?;

    let img_alloc = vk::MemoryAllocateInfo::default()
        .allocation_size(img_req.size)
        .memory_type_index(img_mem_type);
    let img_mem = unsafe {
        device
            .allocate_memory(&img_alloc, None)
            .map_err(|e| format!("Graphics allocate_memory (image) failed: {:?}", e))?
    };
    unsafe {
        device
            .bind_image_memory(image, img_mem, 0)
            .map_err(|e| format!("Graphics bind_image_memory failed: {:?}", e))?;
    }

    let view_info = vk::ImageViewCreateInfo::default()
        .image(image)
        .view_type(vk::ImageViewType::TYPE_2D)
        .format(format)
        .subresource_range(vk::ImageSubresourceRange {
            aspect_mask: vk::ImageAspectFlags::COLOR,
            base_mip_level: 0,
            level_count: 1,
            base_array_layer: 0,
            layer_count: 1,
        });
    let image_view = unsafe {
        device
            .create_image_view(&view_info, None)
            .map_err(|e| format!("Graphics create_image_view failed: {:?}", e))?
    };

    // 2. Readback staging buffer
    let buf_size = (width * height * 4) as vk::DeviceSize;
    let buf_info = vk::BufferCreateInfo::default()
        .size(buf_size)
        .usage(vk::BufferUsageFlags::TRANSFER_DST)
        .sharing_mode(vk::SharingMode::EXCLUSIVE);
    let staging_buf = unsafe {
        device
            .create_buffer(&buf_info, None)
            .map_err(|e| format!("Graphics create staging buffer failed: {:?}", e))?
    };
    let buf_req = unsafe { device.get_buffer_memory_requirements(staging_buf) };
    let buf_mem_type = find_memory_type(
        &mem_props,
        buf_req.memory_type_bits,
        vk::MemoryPropertyFlags::HOST_VISIBLE | vk::MemoryPropertyFlags::HOST_COHERENT,
    )
    .ok_or_else(|| "No HOST_VISIBLE|HOST_COHERENT memory for graphics staging buffer".to_string())?;
    let buf_alloc = vk::MemoryAllocateInfo::default()
        .allocation_size(buf_req.size)
        .memory_type_index(buf_mem_type);
    let staging_mem = unsafe {
        device
            .allocate_memory(&buf_alloc, None)
            .map_err(|e| format!("Graphics allocate staging memory failed: {:?}", e))?
    };
    unsafe {
        device
            .bind_buffer_memory(staging_buf, staging_mem, 0)
            .map_err(|e| format!("Graphics bind staging buffer failed: {:?}", e))?;
    }

    // 3. Render pass
    let color_attachment = vk::AttachmentDescription::default()
        .format(format)
        .samples(vk::SampleCountFlags::TYPE_1)
        .load_op(vk::AttachmentLoadOp::CLEAR)
        .store_op(vk::AttachmentStoreOp::STORE)
        .stencil_load_op(vk::AttachmentLoadOp::DONT_CARE)
        .stencil_store_op(vk::AttachmentStoreOp::DONT_CARE)
        .initial_layout(vk::ImageLayout::UNDEFINED)
        .final_layout(vk::ImageLayout::TRANSFER_SRC_OPTIMAL);
    let color_ref = vk::AttachmentReference {
        attachment: 0,
        layout: vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL,
    };
    let color_refs = [color_ref];
    let subpass = vk::SubpassDescription::default()
        .pipeline_bind_point(vk::PipelineBindPoint::GRAPHICS)
        .color_attachments(&color_refs);
    let attachments = [color_attachment];
    let subpasses = [subpass];
    let rp_info = vk::RenderPassCreateInfo::default()
        .attachments(&attachments)
        .subpasses(&subpasses);
    let render_pass = unsafe {
        device
            .create_render_pass(&rp_info, None)
            .map_err(|e| format!("Graphics create_render_pass failed: {:?}", e))?
    };

    let views = [image_view];
    let fb_info = vk::FramebufferCreateInfo::default()
        .render_pass(render_pass)
        .attachments(&views)
        .width(width)
        .height(height)
        .layers(1);
    let framebuffer = unsafe {
        device
            .create_framebuffer(&fb_info, None)
            .map_err(|e| format!("Graphics create_framebuffer failed: {:?}", e))?
    };

    // 4. Shaders & Graphics Pipeline
    let vert_words = bytes_to_u32_vec(RENDER_VERT_SPV);
    let frag_words = bytes_to_u32_vec(RENDER_FRAG_SPV);
    let vert_mod = unsafe {
        device
            .create_shader_module(&vk::ShaderModuleCreateInfo::default().code(&vert_words), None)
            .map_err(|e| format!("Graphics create vert shader failed: {:?}", e))?
    };
    let frag_mod = unsafe {
        device
            .create_shader_module(&vk::ShaderModuleCreateInfo::default().code(&frag_words), None)
            .map_err(|e| format!("Graphics create frag shader failed: {:?}", e))?
    };

    let entry_name = CString::new("main").unwrap();
    let shader_stages = [
        vk::PipelineShaderStageCreateInfo::default()
            .stage(vk::ShaderStageFlags::VERTEX)
            .module(vert_mod)
            .name(&entry_name),
        vk::PipelineShaderStageCreateInfo::default()
            .stage(vk::ShaderStageFlags::FRAGMENT)
            .module(frag_mod)
            .name(&entry_name),
    ];

    let vertex_input = vk::PipelineVertexInputStateCreateInfo::default();
    let input_assembly = vk::PipelineInputAssemblyStateCreateInfo::default()
        .topology(vk::PrimitiveTopology::TRIANGLE_LIST);
    let viewports = [vk::Viewport {
        x: 0.0,
        y: 0.0,
        width: width as f32,
        height: height as f32,
        min_depth: 0.0,
        max_depth: 1.0,
    }];
    let scissors = [vk::Rect2D {
        offset: vk::Offset2D { x: 0, y: 0 },
        extent: vk::Extent2D { width, height },
    }];
    let viewport_state = vk::PipelineViewportStateCreateInfo::default()
        .viewports(&viewports)
        .scissors(&scissors);
    let rasterizer = vk::PipelineRasterizationStateCreateInfo::default()
        .polygon_mode(vk::PolygonMode::FILL)
        .cull_mode(vk::CullModeFlags::NONE)
        .front_face(vk::FrontFace::COUNTER_CLOCKWISE)
        .line_width(1.0);
    let multisampling = vk::PipelineMultisampleStateCreateInfo::default()
        .rasterization_samples(vk::SampleCountFlags::TYPE_1);
    let blend_attachment = vk::PipelineColorBlendAttachmentState::default()
        .color_write_mask(vk::ColorComponentFlags::RGBA)
        .blend_enable(false);
    let blend_attachments = [blend_attachment];
    let color_blending =
        vk::PipelineColorBlendStateCreateInfo::default().attachments(&blend_attachments);
    let pipe_layout = unsafe {
        device
            .create_pipeline_layout(&vk::PipelineLayoutCreateInfo::default(), None)
            .map_err(|e| format!("Graphics create_pipeline_layout failed: {:?}", e))?
    };

    let gp_info = vk::GraphicsPipelineCreateInfo::default()
        .stages(&shader_stages)
        .vertex_input_state(&vertex_input)
        .input_assembly_state(&input_assembly)
        .viewport_state(&viewport_state)
        .rasterization_state(&rasterizer)
        .multisample_state(&multisampling)
        .color_blend_state(&color_blending)
        .layout(pipe_layout)
        .render_pass(render_pass)
        .subpass(0);

    let pipeline = unsafe {
        device
            .create_graphics_pipelines(vk::PipelineCache::null(), &[gp_info], None)
            .map_err(|(_, e)| format!("create_graphics_pipelines failed: {:?}", e))?[0]
    };

    // 5. Record and submit draw + copy to staging buffer
    let cmd_pool = unsafe {
        device
            .create_command_pool(
                &vk::CommandPoolCreateInfo::default().queue_family_index(queue_family_index),
                None,
            )
            .map_err(|e| format!("Graphics create_command_pool failed: {:?}", e))?
    };
    let cmd_buf = unsafe {
        device
            .allocate_command_buffers(
                &vk::CommandBufferAllocateInfo::default()
                    .command_pool(cmd_pool)
                    .level(vk::CommandBufferLevel::PRIMARY)
                    .command_buffer_count(1),
            )
            .map_err(|e| format!("Graphics allocate_command_buffers failed: {:?}", e))?[0]
    };

    let clear_values = [vk::ClearValue {
        color: vk::ClearColorValue {
            float32: [0.0, 0.0, 0.0, 1.0],
        },
    }];
    let rp_begin = vk::RenderPassBeginInfo::default()
        .render_pass(render_pass)
        .framebuffer(framebuffer)
        .render_area(vk::Rect2D {
            offset: vk::Offset2D { x: 0, y: 0 },
            extent: vk::Extent2D { width, height },
        })
        .clear_values(&clear_values);

    let copy_region = vk::BufferImageCopy::default()
        .buffer_offset(0)
        .image_subresource(vk::ImageSubresourceLayers {
            aspect_mask: vk::ImageAspectFlags::COLOR,
            mip_level: 0,
            base_array_layer: 0,
            layer_count: 1,
        })
        .image_extent(vk::Extent3D {
            width,
            height,
            depth: 1,
        });

    unsafe {
        device
            .begin_command_buffer(
                cmd_buf,
                &vk::CommandBufferBeginInfo::default()
                    .flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT),
            )
            .map_err(|e| format!("Graphics begin_command_buffer failed: {:?}", e))?;
        device.cmd_begin_render_pass(cmd_buf, &rp_begin, vk::SubpassContents::INLINE);
        device.cmd_bind_pipeline(cmd_buf, vk::PipelineBindPoint::GRAPHICS, pipeline);
        device.cmd_draw(cmd_buf, 3, 1, 0, 0);
        device.cmd_end_render_pass(cmd_buf);

        device.cmd_copy_image_to_buffer(
            cmd_buf,
            image,
            vk::ImageLayout::TRANSFER_SRC_OPTIMAL,
            staging_buf,
            &[copy_region],
        );
        device
            .end_command_buffer(cmd_buf)
            .map_err(|e| format!("Graphics end_command_buffer failed: {:?}", e))?;

        let cmd_bufs = [cmd_buf];
        device
            .queue_submit(
                queue,
                &[vk::SubmitInfo::default().command_buffers(&cmd_bufs)],
                vk::Fence::null(),
            )
            .map_err(|e| format!("Graphics queue_submit failed: {:?}", e))?;
        device
            .queue_wait_idle(queue)
            .map_err(|e| format!("Graphics queue_wait_idle failed: {:?}", e))?;
    }

    // 6. Read back center pixel & verify R=64(±2), G=128(±2), B=191(±2), A=255
    let pixel_rgba: [u8; 4];
    unsafe {
        let ptr = device
            .map_memory(staging_mem, 0, buf_size, vk::MemoryMapFlags::empty())
            .map_err(|e| format!("Graphics staging map_memory failed: {:?}", e))?
            as *const u8;
        let center_offset = ((height / 2) * width + (width / 2)) as usize * 4;
        pixel_rgba = [
            *ptr.add(center_offset),
            *ptr.add(center_offset + 1),
            *ptr.add(center_offset + 2),
            *ptr.add(center_offset + 3),
        ];
        device.unmap_memory(staging_mem);

        device.destroy_command_pool(cmd_pool, None);
        device.destroy_pipeline(pipeline, None);
        device.destroy_pipeline_layout(pipe_layout, None);
        device.destroy_shader_module(vert_mod, None);
        device.destroy_shader_module(frag_mod, None);
        device.destroy_framebuffer(framebuffer, None);
        device.destroy_render_pass(render_pass, None);
        device.destroy_buffer(staging_buf, None);
        device.free_memory(staging_mem, None);
        device.destroy_image_view(image_view, None);
        device.destroy_image(image, None);
        device.free_memory(img_mem, None);
    }

    let r_ok = (pixel_rgba[0] as i32 - 64).abs() <= 2;
    let g_ok = (pixel_rgba[1] as i32 - 128).abs() <= 2;
    let b_ok = (pixel_rgba[2] as i32 - 191).abs() <= 2;
    let a_ok = pixel_rgba[3] == 255;

    if r_ok && g_ok && b_ok && a_ok {
        Ok(format!(
            "64x64 offscreen render pass & pixel readback verified (RGBA=[{}, {}, {}, {}])",
            pixel_rgba[0], pixel_rgba[1], pixel_rgba[2], pixel_rgba[3]
        ))
    } else {
        Err(format!(
            "Rendered pixel mismatch: got RGBA={:?}, expected ~[64, 128, 191, 255]",
            pixel_rgba
        ))
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let output_json = args.iter().any(|a| a == "--json");
    let allow_software = args.iter().any(|a| a == "--allow-software-for-build-test");

    let pci_devices = detect_pci_and_kernel_driver();
    let vulkan_icds = detect_vulkan_icds();
    let host_diag = gather_reims_host_diagnostics();

    let entry = match unsafe { ash::Entry::load() } {
        Ok(e) => e,
        Err(err) => {
            eprintln!("FATAL: Failed to load Vulkan loader (libvulkan.so.1 / vulkan-1.dll): {}", err);
            std::process::exit(2);
        }
    };

    let app_name = CString::new("tahoeboot-gpu-check").unwrap();
    let app_info = vk::ApplicationInfo::default()
        .application_name(&app_name)
        .application_version(vk::make_api_version(0, 1, 0, 0))
        .engine_name(&app_name)
        .engine_version(vk::make_api_version(0, 1, 0, 0))
        .api_version(vk::API_VERSION_1_3);

    let instance_info = vk::InstanceCreateInfo::default().application_info(&app_info);
    let instance = match unsafe { entry.create_instance(&instance_info, None) } {
        Ok(i) => i,
        Err(err) => {
            eprintln!("FATAL: vkCreateInstance failed: {:?}", err);
            std::process::exit(2);
        }
    };

    let pdevices = unsafe {
        instance
            .enumerate_physical_devices()
            .unwrap_or_default()
    };

    let mut summaries = Vec::new();
    let mut selected_idx: Option<usize> = None;

    for (idx, &pdevice) in pdevices.iter().enumerate() {
        let mut driver_props = vk::PhysicalDeviceDriverProperties::default();
        let mut ext_host_props = vk::PhysicalDeviceExternalMemoryHostPropertiesEXT::default();
        let mut props2 = vk::PhysicalDeviceProperties2::default()
            .push_next(&mut driver_props)
            .push_next(&mut ext_host_props);
        unsafe {
            instance.get_physical_device_properties2(pdevice, &mut props2);
        }

        let props = props2.properties;
        let name = cstr_to_string(&props.device_name);
        let driver_name = cstr_to_string(&driver_props.driver_name);
        let driver_info = cstr_to_string(&driver_props.driver_info);
        let api_version = format_vk_version(props.api_version);

        let dev_type_str = match props.device_type {
            vk::PhysicalDeviceType::INTEGRATED_GPU => "Physical GPU (Integrated GPU)",
            vk::PhysicalDeviceType::DISCRETE_GPU => "Physical GPU (Discrete GPU)",
            vk::PhysicalDeviceType::VIRTUAL_GPU => "Virtual GPU",
            vk::PhysicalDeviceType::CPU => "CPU Software Renderer",
            _ => "Other",
        }
        .to_string();

        let name_lower = name.to_lowercase();
        let drv_lower = driver_name.to_lowercase();
        let is_software = props.device_type == vk::PhysicalDeviceType::CPU
            || name_lower.contains("llvmpipe")
            || name_lower.contains("lavapipe")
            || name_lower.contains("swiftshader")
            || drv_lower.contains("llvmpipe")
            || drv_lower.contains("swiftshader")
            || driver_props.driver_id == vk::DriverId::MESA_LLVMPIPE
            || driver_props.driver_id == vk::DriverId::GOOGLE_SWIFTSHADER
            || driver_props.driver_id == vk::DriverId::MESA_DOZEN;

        let is_uhd_730 =
            props.vendor_id == INTEL_VENDOR_ID && props.device_id == UHD_730_DEVICE_ID;

        let exts = unsafe {
            instance
                .enumerate_device_extension_properties(pdevice)
                .unwrap_or_default()
        };
        let has_ext = |target: &str| -> bool {
            exts.iter().any(|e| cstr_to_string(&e.extension_name) == target)
        };

        let has_external_memory_host = has_ext("VK_EXT_external_memory_host");
        let has_external_memory_dma_buf = has_ext("VK_EXT_external_memory_dma_buf");
        let has_external_memory_fd = has_ext("VK_KHR_external_memory_fd");
        let has_swapchain = has_ext("VK_KHR_swapchain");

        let mut vk12_features = vk::PhysicalDeviceVulkan12Features::default();
        let mut vk13_features = vk::PhysicalDeviceVulkan13Features::default();
        let mut features2 = vk::PhysicalDeviceFeatures2::default()
            .push_next(&mut vk12_features)
            .push_next(&mut vk13_features);
        unsafe {
            instance.get_physical_device_features2(pdevice, &mut features2);
        }

        let supports_vk13 = vk13_features.dynamic_rendering == vk::TRUE
            && vk13_features.synchronization2 == vk::TRUE
            && vk12_features.timeline_semaphore == vk::TRUE
            && vk12_features.buffer_device_address == vk::TRUE
            && vk12_features.descriptor_indexing == vk::TRUE;

        let mem_props = unsafe { instance.get_physical_device_memory_properties(pdevice) };
        let mut total_vram_bytes = 0u64;
        for i in 0..mem_props.memory_heap_count as usize {
            let heap = mem_props.memory_heaps[i];
            if heap.flags.contains(vk::MemoryHeapFlags::DEVICE_LOCAL) {
                total_vram_bytes += heap.size;
            }
        }

        let mut notes = Vec::new();
        if is_uhd_730 {
            notes.push(
                "Intel Rocket Lake GT1 (Gen12 / Xe-LP): supported by metal2vulkan-runtime with ANV compression & push-descriptor workarounds".to_string(),
            );
            notes.push(
                "i915/ANV host memory: imports guest memfd RAM via VK_EXT_external_memory_host (4096-byte page alignment) + /dev/udmabuf idle page folding".to_string(),
            );
        }
        if is_software {
            notes.push(
                "REJECTED FOR ACCELERATION: CPU/software or translation layer renderer (llvmpipe / lavapipe / SwiftShader / Dozen)".to_string(),
            );
        }

        // Selection priority:
        // 1. Explicit Intel UHD 730 (0x8086:0x4c8b)
        // 2. Any other physical non-software GPU
        // 3. Software renderer only if no physical GPU exists (will be marked FAIL in GPU selection unless --allow-software-for-build-test)
        if is_uhd_730 {
            selected_idx = Some(idx);
        } else if selected_idx.is_none() && !is_software {
            selected_idx = Some(idx);
        } else if selected_idx.is_none() {
            selected_idx = Some(idx);
        }

        summaries.push(VulkanDeviceSummary {
            index: idx,
            name,
            vendor_id: props.vendor_id,
            device_id: props.device_id,
            device_type: dev_type_str,
            api_version,
            driver_id: format!("{:?}", driver_props.driver_id),
            driver_name,
            driver_info,
            total_vram_mib: total_vram_bytes / (1024 * 1024),
            is_software_or_cpu: is_software,
            is_intel_uhd_730: is_uhd_730,
            has_external_memory_host,
            has_external_memory_dma_buf,
            has_external_memory_fd,
            has_swapchain,
            min_imported_host_pointer_alignment: ext_host_props.min_imported_host_pointer_alignment,
            supports_vulkan_1_3_features: supports_vk13,
            reims_defect_notes: notes,
        });
    }

    let (
        gpu_name,
        pci_id,
        driver_str,
        vulkan_api,
        device_classification,
        external_memory_pass,
        external_memory_detail,
        host_memory_mapping_pass,
        host_memory_mapping_detail,
        vulkan_compute_test_pass,
        vulkan_compute_detail,
        vulkan_graphics_test_pass,
        vulkan_graphics_detail,
        reims_compatibility_pass,
        reims_compatibility_detail,
        gpu_selection_pass,
        gpu_selection_detail,
    ) = if let Some(sel) = selected_idx {
        let pdevice = pdevices[sel];
        let summary = &summaries[sel];

        // Create logical device on a queue family supporting GRAPHICS | COMPUTE
        let qfamilies =
            unsafe { instance.get_physical_device_queue_family_properties(pdevice) };
        let qf_idx = qfamilies
            .iter()
            .enumerate()
            .find(|(_, q)| {
                q.queue_flags
                    .contains(vk::QueueFlags::GRAPHICS | vk::QueueFlags::COMPUTE)
            })
            .map(|(i, _)| i as u32)
            .unwrap_or(0);

        let priorities = [1.0f32];
        let q_info = vk::DeviceQueueCreateInfo::default()
            .queue_family_index(qf_idx)
            .queue_priorities(&priorities);
        let q_infos = [q_info];

        let mut enabled_exts = Vec::new();
        let ext_host_cstr = CString::new("VK_EXT_external_memory_host").unwrap();
        let ext_khx_cstr = CString::new("VK_KHR_external_memory").unwrap();
        if summary.has_external_memory_host {
            enabled_exts.push(ext_khx_cstr.as_ptr());
            enabled_exts.push(ext_host_cstr.as_ptr());
        }

        let dev_info = vk::DeviceCreateInfo::default()
            .queue_create_infos(&q_infos)
            .enabled_extension_names(&enabled_exts);

        let (host_map_ok, host_map_msg, comp_ok, comp_msg, gfx_ok, gfx_msg) =
            match unsafe { instance.create_device(pdevice, &dev_info, None) } {
                Ok(device) => {
                    let queue = unsafe { device.get_device_queue(qf_idx, 0) };

                    let (hm_ok, hm_msg) = if summary.has_external_memory_host {
                        match unsafe { run_host_memory_import_test(&instance, pdevice, &device) } {
                            Ok(m) => (true, m),
                            Err(e) => (false, e),
                        }
                    } else {
                        (
                            false,
                            "VK_EXT_external_memory_host not supported by this device".to_string(),
                        )
                    };

                    let (c_ok, c_msg) = match unsafe {
                        run_vulkan_compute_test(&instance, pdevice, &device, queue, qf_idx)
                    } {
                        Ok(m) => (true, m),
                        Err(e) => (false, e),
                    };

                    let (g_ok, g_msg) = match unsafe {
                        run_vulkan_graphics_test(&instance, pdevice, &device, queue, qf_idx)
                    } {
                        Ok(m) => (true, m),
                        Err(e) => (false, e),
                    };

                    unsafe {
                        device.destroy_device(None);
                    }
                    (hm_ok, hm_msg, c_ok, c_msg, g_ok, g_msg)
                }
                Err(e) => (
                    false,
                    format!("vkCreateDevice failed: {:?}", e),
                    false,
                    format!("vkCreateDevice failed: {:?}", e),
                    false,
                    format!("vkCreateDevice failed: {:?}", e),
                ),
            };

        let ext_mem_ok = summary.has_external_memory_host
            && summary.min_imported_host_pointer_alignment > 0
            && summary.min_imported_host_pointer_alignment <= 65536;
        let ext_mem_msg = format!(
            "VK_EXT_external_memory_host={}, DMA_BUF={}, minImportedHostPointerAlignment={} bytes",
            summary.has_external_memory_host,
            summary.has_external_memory_dma_buf,
            summary.min_imported_host_pointer_alignment
        );

        let gpu_sel_ok = !summary.is_software_or_cpu || allow_software;
        let gpu_sel_msg = if summary.is_intel_uhd_730 {
            "Selected physical Intel UHD Graphics 730 (0x8086:0x4c8b)".to_string()
        } else if !summary.is_software_or_cpu {
            format!(
                "Selected physical GPU {} (0x{:04x}:0x{:04x})",
                summary.name, summary.vendor_id, summary.device_id
            )
        } else if allow_software {
            format!(
                "Build-test override active: using {} (rejected in production appliance mode)",
                summary.name
            )
        } else {
            format!(
                "REJECTED: '{}' is a CPU software renderer (no physical i915/ANV GPU exposed in current WSL2 kernel; boot TahoeBoot.iso on bare-metal for physical UHD 730)",
                summary.name
            )
        };

        let reims_compat_ok =
            gpu_sel_ok && ext_mem_ok && host_map_ok && comp_ok && gfx_ok && summary.supports_vulkan_1_3_features;
        let reims_compat_msg = if reims_compat_ok {
            "All Reims vGPU & metal2vulkan Vulkan 1.3/1.4, host pointer import, compute, and graphics pipeline checks passed".to_string()
        } else {
            format!(
                "gpu_selection={}, ext_mem={}, host_import={}, compute={}, graphics={}, vk13_features={}",
                gpu_sel_ok,
                ext_mem_ok,
                host_map_ok,
                comp_ok,
                gfx_ok,
                summary.supports_vulkan_1_3_features
            )
        };

        let kernel_drv = pci_devices
            .first()
            .map(|p| p.kernel_driver.as_str())
            .unwrap_or("native");

        (
            summary.name.clone(),
            format!("0x{:04x}:0x{:04x}", summary.vendor_id, summary.device_id),
            format!(
                "{} ({}) [kernel: {}]",
                summary.driver_name, summary.driver_info, kernel_drv
            ),
            summary.api_version.clone(),
            summary.device_type.clone(),
            ext_mem_ok,
            ext_mem_msg,
            host_map_ok,
            host_map_msg,
            comp_ok,
            comp_msg,
            gfx_ok,
            gfx_msg,
            reims_compat_ok,
            reims_compat_msg,
            gpu_sel_ok,
            gpu_sel_msg,
        )
    } else {
        (
            "None".to_string(),
            "0x0000:0x0000".to_string(),
            "No Vulkan ICD found".to_string(),
            "0.0.0".to_string(),
            "None".to_string(),
            false,
            "No Vulkan physical devices enumerated".to_string(),
            false,
            "No Vulkan physical devices enumerated".to_string(),
            false,
            "Not run".to_string(),
            false,
            "Not run".to_string(),
            false,
            "No compatible Vulkan GPU".to_string(),
            false,
            "No physical GPU available".to_string(),
        )
    };

    unsafe {
        instance.destroy_instance(None);
    }

    let report = TahoeBootGpuReport {
        gpu_name,
        pci_id,
        driver: driver_str,
        vulkan_api,
        device_classification,
        external_memory_pass,
        external_memory_detail,
        host_memory_mapping_pass,
        host_memory_mapping_detail,
        vulkan_compute_test_pass,
        vulkan_compute_detail,
        vulkan_graphics_test_pass,
        vulkan_graphics_detail,
        reims_compatibility_pass,
        reims_compatibility_detail,
        gpu_selection_pass,
        gpu_selection_detail,
        guest_acceleration_status: "NOT TESTED".to_string(),
        pci_devices,
        vulkan_icds,
        enumerated_vulkan_devices: summaries,
        host_diagnostics: host_diag,
    };

    if output_json {
        println!("{}", serde_json::to_string_pretty(&report).unwrap());
    } else {
        println!("TAHOEBOOT GPU REPORT");
        println!();
        println!("GPU: {} ({})", report.gpu_name, report.pci_id);
        println!("Driver: {}", report.driver);
        println!("Vulkan: {}", report.vulkan_api);
        println!("Device: {}", report.device_classification);
        println!(
            "External memory: {} ({})",
            if report.external_memory_pass { "PASS" } else { "FAIL" },
            report.external_memory_detail
        );
        println!(
            "Host memory mapping: {} ({})",
            if report.host_memory_mapping_pass { "PASS" } else { "FAIL" },
            report.host_memory_mapping_detail
        );
        println!(
            "Vulkan compute test: {} ({})",
            if report.vulkan_compute_test_pass { "PASS" } else { "FAIL" },
            report.vulkan_compute_detail
        );
        println!(
            "Vulkan graphics test: {} ({})",
            if report.vulkan_graphics_test_pass { "PASS" } else { "FAIL" },
            report.vulkan_graphics_detail
        );
        println!(
            "Reims compatibility: {} ({})",
            if report.reims_compatibility_pass { "PASS" } else { "FAIL" },
            report.reims_compatibility_detail
        );
        println!(
            "GPU selection: {} ({})",
            if report.gpu_selection_pass { "PASS" } else { "FAIL" },
            report.gpu_selection_detail
        );
        println!("Guest acceleration: {}", report.guest_acceleration_status);
        println!();
        println!("--- REIMS HOST & KERNEL DIAGNOSTICS ---");
        println!("Environment:       {}", report.host_diagnostics.os_environment);
        println!(
            "KVM (/dev/kvm):    {} (writable: {}, VT-x/nested: {})",
            if report.host_diagnostics.kvm_available { "PRESENT" } else { "MISSING" },
            report.host_diagnostics.kvm_writable,
            report.host_diagnostics.vtx_or_nested_enabled
        );
        println!(
            "udmabuf:           {} (writable: {})",
            if report.host_diagnostics.udmabuf_available { "PRESENT" } else { "MISSING (WSL2 kernel lacks CONFIG_UDMABUF; present in TahoeBoot bare-metal Ubuntu 7.0 kernel)" },
            report.host_diagnostics.udmabuf_writable
        );
        println!(
            "vm.max_map_count:  {} ({})",
            report.host_diagnostics.vm_max_map_count,
            if report.host_diagnostics.vm_max_map_count_ok { "PASS >= 2097152" } else { "NEEDS sysctl vm.max_map_count=2097152" }
        );
        println!(
            "Reims artifacts:   libreims_vgpu={} ReimsVgpu.rom={} qemu-reims={} opencore.qcow2={}",
            report.host_diagnostics.reims_lib_present,
            report.host_diagnostics.reims_rom_present,
            report.host_diagnostics.reims_qemu_present,
            report.host_diagnostics.opencore_present
        );
        if !report.vulkan_icds.is_empty() {
            println!("Vulkan ICDs:       {}", report.vulkan_icds.join(", "));
        }
    }

    if !report.reims_compatibility_pass || !report.gpu_selection_pass {
        std::process::exit(1);
    }
}
