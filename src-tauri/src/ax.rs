use core_foundation::base::{CFRetain, CFRelease, CFType, CFTypeRef, TCFType};
use core_foundation::string::{CFString, CFStringRef};
use std::ptr;

pub(crate) const AX_ERROR_SUCCESS: i32 = 0;

pub(crate) type AXUIElementRef = *const std::ffi::c_void;

extern "C" {
    pub(crate) fn objc_getClass(name: *const i8) -> *const std::ffi::c_void;
    pub(crate) fn sel_registerName(str: *const i8) -> *const std::ffi::c_void;
    pub(crate) fn objc_msgSend(
        obj: *mut std::ffi::c_void,
        sel: *const std::ffi::c_void,
        ...
    ) -> *mut std::ffi::c_void;
}

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    pub(crate) fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    pub(crate) fn AXUIElementGetPid(element: AXUIElementRef, pid: *mut i32) -> i32;
    pub(crate) fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
    pub(crate) fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: *mut CFTypeRef,
    ) -> i32;
    pub(crate) fn AXUIElementCopyElementAtPosition(
        application: AXUIElementRef,
        x: f32,
        y: f32,
        element: *mut AXUIElementRef,
    ) -> i32;
    pub(crate) fn AXUIElementCopyParameterizedAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        parameter: CFTypeRef,
        value: *mut CFTypeRef,
    ) -> i32;
    pub(crate) fn AXUIElementIsAttributeSettable(
        element: AXUIElementRef,
        attribute: CFStringRef,
        settable: *mut bool,
    ) -> i32;
    pub(crate) fn AXUIElementSetAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: CFTypeRef,
    ) -> i32;
    pub(crate) fn AXValueCreate(
        value_type: u32,
        value_ptr: *const std::ffi::c_void,
    ) -> CFTypeRef;
    pub(crate) fn AXValueGetValue(
        value: CFTypeRef,
        the_type: u32,
        range_ptr: *mut std::ffi::c_void,
    ) -> bool;
    pub(crate) fn AXUIElementPerformAction(element: AXUIElementRef, action: CFStringRef) -> i32;
    pub(crate) fn IsSecureEventInputEnabled() -> bool;
    pub(crate) fn AXUIElementSetMessagingTimeout(
        element: AXUIElementRef,
        timeout: f32,
    ) -> i32;
    pub(crate) fn CFBooleanGetValue(boolean: core_foundation::boolean::CFBooleanRef) -> bool;
}

extern "C" {
    pub(crate) fn CFArrayGetCount(the_array: *const std::ffi::c_void) -> isize;
    pub(crate) fn CFArrayGetValueAtIndex(
        the_array: *const std::ffi::c_void,
        idx: isize,
    ) -> *const std::ffi::c_void;
}

/// String attribute of an AX element (`AXValue`, `AXSelectedText`, `AXRole`, …).
pub(crate) fn accessibility_string_attribute(
    element: AXUIElementRef,
    attribute: &'static str,
) -> Option<String> {
    unsafe {
        let attribute = CFString::from_static_string(attribute);
        let mut value: CFTypeRef = ptr::null();
        let result =
            AXUIElementCopyAttributeValue(element, attribute.as_concrete_TypeRef(), &mut value);
        if result != AX_ERROR_SUCCESS || value.is_null() {
            return None;
        }

        let value = CFType::wrap_under_create_rule(value);
        value.downcast::<CFString>().map(|text| text.to_string())
    }
}

/// Boolean attribute of an AX element (`AXEnabled`, …).
pub(crate) fn accessibility_bool_attribute(
    element: AXUIElementRef,
    attribute: &'static str,
) -> Option<bool> {
    unsafe {
        let attr = CFString::from_static_string(attribute);
        let mut value: CFTypeRef = ptr::null();
        if AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value)
            != AX_ERROR_SUCCESS
            || value.is_null()
        {
            return None;
        }
        let is_true = CFBooleanGetValue(value as core_foundation::boolean::CFBooleanRef);
        CFRelease(value);
        Some(is_true)
    }
}

/// Copy an attribute whose value is another AXUIElement (retained; caller
/// releases) — AXParent / AXFocusedUIElement / AXFocusedWindow.
pub(crate) unsafe fn copy_ax_element_attribute(
    element: AXUIElementRef,
    attribute: &'static str,
) -> Option<AXUIElementRef> {
    let attr = CFString::from_static_string(attribute);
    let mut value: CFTypeRef = ptr::null();
    if AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value)
        != AX_ERROR_SUCCESS
        || value.is_null()
    {
        return None;
    }
    Some(value as AXUIElementRef)
}

/// Focused UI element of an application element (retained; caller releases).
/// Taken from the application, never the system-wide element — the system-wide
/// focused element is a classic stale-read source.
pub(crate) unsafe fn focused_element_of(app: AXUIElementRef) -> Option<AXUIElementRef> {
    copy_ax_element_attribute(app, "AXFocusedUIElement")
}

/// Focused application AXUIElement (retained; caller must `CFRelease`).
pub(crate) unsafe fn ax_focused_application() -> Option<AXUIElementRef> {
    // Use NSWorkspace's frontmost pid → AXUIElementCreateApplication. The
    // `AXFocusedApplication` attribute on the system-wide element is unreliable:
    // some apps (certain Tauri/Electron apps) report no focused application at
    // all, which would silently kill AX-dependent fallbacks.
    let pid = frontmost_pid()?;
    let app = AXUIElementCreateApplication(pid);
    if app.is_null() {
        return None;
    }
    Some(app)
}

/// `AXChildren` of an element as retained `AXUIElementRef`s (caller releases).
pub(crate) unsafe fn ax_children(element: AXUIElementRef) -> Vec<AXUIElementRef> {
    let mut value: CFTypeRef = ptr::null();
    let attr = CFString::from_static_string("AXChildren");
    if AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value)
        != AX_ERROR_SUCCESS
        || value.is_null()
    {
        return Vec::new();
    }
    let count = CFArrayGetCount(value as *const std::ffi::c_void);
    let mut out = Vec::with_capacity(count.max(0) as usize);
    for i in 0..count {
        let child =
            CFArrayGetValueAtIndex(value as *const std::ffi::c_void, i) as AXUIElementRef;
        if !child.is_null() {
            CFRetain(child);
            out.push(child);
        }
    }
    CFRelease(value);
    out
}

/// Whether an element's attribute can be written.
pub(crate) unsafe fn ax_attribute_settable(
    element: AXUIElementRef,
    attribute: &'static str,
) -> bool {
    let attr = CFString::from_static_string(attribute);
    let mut settable = false;
    AXUIElementIsAttributeSettable(element, attr.as_concrete_TypeRef(), &mut settable)
        == AX_ERROR_SUCCESS
        && settable
}

/// Write a string attribute (e.g. `AXSelectedText`) onto an element.
pub(crate) unsafe fn ax_set_string_attribute(
    element: AXUIElementRef,
    attribute: &'static str,
    value: &str,
) -> bool {
    let attr = CFString::from_static_string(attribute);
    let cf_value = CFString::new(value);
    AXUIElementSetAttributeValue(
        element,
        attr.as_concrete_TypeRef(),
        cf_value.as_concrete_TypeRef() as CFTypeRef,
    ) == AX_ERROR_SUCCESS
}

/// `AXSelectedTextRange` as a UTF-16 (NSRange-style) range. The AX API reports
/// ranges in UTF-16 offsets, matching Swift's String/NSRange bridging.
pub(crate) unsafe fn ax_selected_range(element: AXUIElementRef) -> Option<(usize, usize)> {
    let attr = CFString::from_static_string("AXSelectedTextRange");
    let mut value: CFTypeRef = ptr::null();
    if AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value)
        != AX_ERROR_SUCCESS
        || value.is_null()
    {
        return None;
    }
    let mut range = core_foundation::base::CFRange { location: 0, length: 0 };
    let ok = AXValueGetValue(
        value,
        2, // kAXValueCFRangeType
        &mut range as *mut _ as *mut std::ffi::c_void,
    );
    CFRelease(value);
    if !ok {
        return None;
    }
    Some((range.location as usize, range.length as usize))
}

/// Write `AXSelectedTextRange` (UTF-16 offsets).
pub(crate) unsafe fn ax_set_selected_range(
    element: AXUIElementRef,
    location: usize,
    length: usize,
) -> bool {
    let attr = CFString::from_static_string("AXSelectedTextRange");
    let mut range = core_foundation::base::CFRange {
        location: location.min(isize::MAX as usize) as isize,
        length: length.min(isize::MAX as usize) as isize,
    };
    let value = AXValueCreate(
        2, // kAXValueCFRangeType
        &mut range as *mut _ as *const std::ffi::c_void,
    );
    if value.is_null() {
        return false;
    }
    let ok = AXUIElementSetAttributeValue(element, attr.as_concrete_TypeRef(), value)
        == AX_ERROR_SUCCESS;
    CFRelease(value);
    ok
}

/// `AXSelectedTextMarkerRange` of an element (retained opaque CFType; caller
/// releases). Present only on renderer surfaces (Chromium/Monaco) — their AX
/// value trails or stays empty, so text injection must bypass the AX write tier.
pub(crate) unsafe fn copy_marker_range(element: AXUIElementRef) -> Option<CFTypeRef> {
    let attr = CFString::from_static_string("AXSelectedTextMarkerRange");
    let mut value: CFTypeRef = ptr::null();
    if AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value)
        != AX_ERROR_SUCCESS
        || value.is_null()
    {
        return None;
    }
    Some(value)
}

/// Whether the element is a renderer surface that keeps its selection in text
/// markers (and therefore must not be written to over AX).
pub(crate) unsafe fn element_has_marker_selection(element: AXUIElementRef) -> bool {
    match copy_marker_range(element) {
        Some(range) => {
            CFRelease(range);
            true
        }
        None => false,
    }
}

/// Whether a secure text entry field currently holds the keyboard (login
/// window, sudo prompt, password fields). Never inject keystrokes then.
pub(crate) fn secure_input_enabled() -> bool {
    unsafe { IsSecureEventInputEnabled() }
}

/// pid of the current frontmost application (via NSWorkspace), wrapped in an
/// autorelease pool because `frontmostApplication` returns an autoreleased
/// NSRunningApplication.
pub(crate) unsafe fn frontmost_pid() -> Option<i32> {
    let pool = new_autorelease_pool();
    let pid = frontmost_pid_inner();
    drain_autorelease_pool(pool);
    pid
}

unsafe fn frontmost_pid_inner() -> Option<i32> {
    let cls = objc_getClass(b"NSWorkspace\0".as_ptr() as *const i8);
    if cls.is_null() {
        return None;
    }
    let shared_sel = sel_registerName(b"sharedWorkspace\0".as_ptr() as *const i8);
    let workspace = objc_msgSend(cls as *mut std::ffi::c_void, shared_sel);
    if workspace.is_null() {
        return None;
    }
    let frontmost_sel = sel_registerName(b"frontmostApplication\0".as_ptr() as *const i8);
    let running_app = objc_msgSend(workspace, frontmost_sel);
    if running_app.is_null() {
        return None;
    }
    let pid_sel = sel_registerName(b"processIdentifier\0".as_ptr() as *const i8);
    let pid = objc_msgSend(running_app, pid_sel) as i32;
    if pid <= 0 {
        return None;
    }
    Some(pid)
}

pub(crate) unsafe fn new_autorelease_pool() -> *mut std::ffi::c_void {
    let cls = objc_getClass(b"NSAutoreleasePool\0".as_ptr() as *const i8);
    if cls.is_null() {
        return ptr::null_mut();
    }
    let alloc = sel_registerName(b"alloc\0".as_ptr() as *const i8);
    let obj = objc_msgSend(cls as *mut std::ffi::c_void, alloc);
    let init = sel_registerName(b"init\0".as_ptr() as *const i8);
    objc_msgSend(obj, init)
}

pub(crate) unsafe fn drain_autorelease_pool(pool: *mut std::ffi::c_void) {
    if pool.is_null() {
        return;
    }
    let drain = sel_registerName(b"drain\0".as_ptr() as *const i8);
    objc_msgSend(pool, drain);
}
