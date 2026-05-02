use core_graphics::event::{CGEvent, CGMouseButton};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use serde::Deserialize;
use std::thread;
use std::time::{Duration, Instant};
use tauri::{PhysicalPosition, PhysicalSize, WebviewWindow};

const MIN_POPUP_WIDTH: u32 = 360;
const MIN_POPUP_HEIGHT: u32 = 360;
const MAX_POPUP_HEIGHT: u32 = 900;
const MAX_RESIZE_DURATION: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Deserialize)]
pub enum ResizeDirection {
    East,
    North,
    NorthEast,
    NorthWest,
    South,
    SouthEast,
    SouthWest,
    West,
}

#[derive(Clone, Copy)]
struct ResizeGeometry {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
}

#[tauri::command]
pub fn start_popup_resize(window: WebviewWindow, direction: ResizeDirection) -> Result<(), String> {
    let start_position = window
        .outer_position()
        .map_err(|error| format!("Could not read popup position: {error}"))?;
    let start_size = window
        .outer_size()
        .map_err(|error| format!("Could not read popup size: {error}"))?;
    let scale_factor = window
        .scale_factor()
        .map_err(|error| format!("Could not read popup scale factor: {error}"))?;
    let start_cursor = cursor_position(scale_factor)?;
    let resize_window = window.clone();

    thread::spawn(move || {
        let started_at = Instant::now();

        while left_mouse_button_down() && started_at.elapsed() < MAX_RESIZE_DURATION {
            if let Ok(cursor) = cursor_position(scale_factor) {
                let delta_x = cursor.0 - start_cursor.0;
                let delta_y = cursor.1 - start_cursor.1;
                let geometry = resize_geometry(
                    direction,
                    start_position.x,
                    start_position.y,
                    start_size.width,
                    start_size.height,
                    delta_x,
                    delta_y,
                );

                let _ = resize_window.set_position(PhysicalPosition::new(geometry.x, geometry.y));
                let _ = resize_window.set_size(PhysicalSize::new(geometry.width, geometry.height));
            }

            thread::sleep(Duration::from_millis(16));
        }
    });

    Ok(())
}

#[tauri::command]
pub fn set_popup_height(window: WebviewWindow, height: f64) -> Result<(), String> {
    if window.label() != "popup_card" {
        return Ok(());
    }

    let current_size = window
        .outer_size()
        .map_err(|error| format!("Could not read popup size: {error}"))?;
    let scale_factor = window
        .scale_factor()
        .map_err(|error| format!("Could not read popup scale factor: {error}"))?;
    let logical_height = height.round().clamp(MIN_POPUP_HEIGHT as f64, MAX_POPUP_HEIGHT as f64);
    let physical_height = (logical_height * scale_factor).round() as u32;

    window
        .set_size(PhysicalSize::new(current_size.width, physical_height))
        .map_err(|error| format!("Could not set popup height: {error}"))
}

fn cursor_position(scale_factor: f64) -> Result<(i32, i32), String> {
    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
        .map_err(|_| "Could not create mouse event source.".to_string())?;
    let event = CGEvent::new(source).map_err(|_| "Could not read mouse event.".to_string())?;
    let location = event.location();

    Ok((
        (location.x * scale_factor).round() as i32,
        (location.y * scale_factor).round() as i32,
    ))
}

fn left_mouse_button_down() -> bool {
    unsafe { CGEventSourceButtonState(CGEventSourceStateID::HIDSystemState, CGMouseButton::Left) }
}

fn resize_geometry(
    direction: ResizeDirection,
    start_x: i32,
    start_y: i32,
    start_width: u32,
    start_height: u32,
    delta_x: i32,
    delta_y: i32,
) -> ResizeGeometry {
    let mut x = start_x;
    let mut y = start_y;
    let mut width = start_width as i32;
    let mut height = start_height as i32;

    if grows_east(direction) {
        width = (start_width as i32 + delta_x).max(MIN_POPUP_WIDTH as i32);
    }

    if grows_south(direction) {
        height = (start_height as i32 + delta_y).max(MIN_POPUP_HEIGHT as i32);
    }

    if grows_west(direction) {
        width = (start_width as i32 - delta_x).max(MIN_POPUP_WIDTH as i32);
        x = start_x + start_width as i32 - width;
    }

    if grows_north(direction) {
        height = (start_height as i32 - delta_y).max(MIN_POPUP_HEIGHT as i32);
        y = start_y + start_height as i32 - height;
    }

    ResizeGeometry {
        x,
        y,
        width: width as u32,
        height: height as u32,
    }
}

fn grows_east(direction: ResizeDirection) -> bool {
    matches!(direction, ResizeDirection::East | ResizeDirection::NorthEast | ResizeDirection::SouthEast)
}

fn grows_west(direction: ResizeDirection) -> bool {
    matches!(direction, ResizeDirection::West | ResizeDirection::NorthWest | ResizeDirection::SouthWest)
}

fn grows_north(direction: ResizeDirection) -> bool {
    matches!(direction, ResizeDirection::North | ResizeDirection::NorthEast | ResizeDirection::NorthWest)
}

fn grows_south(direction: ResizeDirection) -> bool {
    matches!(direction, ResizeDirection::South | ResizeDirection::SouthEast | ResizeDirection::SouthWest)
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventSourceButtonState(
        state_id: CGEventSourceStateID,
        button: CGMouseButton,
    ) -> bool;
}
