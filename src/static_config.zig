const std = @import("std");
const utils = @import("utils.zig");

const log2 = std.math.log2;
const log2_int = std.math.log2_int;
const assert = std.debug.assert;

pub const SizeClass = struct {
    block_size: u32,
    block_max: u32,
    class_idx: u32,
    aligned: bool,
};

pub const span_size = 65536;
pub const mod_span_size = span_size - 1;

// must be a multiple of small_granularity
pub const span_header_size = 128;
pub const span_effective_size = span_size - span_header_size;
pub const span_max = span_effective_size;

pub const page_size = std.mem.page_size;
pub const page_alignment = log2(page_size);

pub const aligned_spans_offset = log2(span_header_size);
pub const aligned_class_count = log2(medium_max) - aligned_spans_offset;

pub const span_align_max = std.math.pow(u16, 2, log2_int(u16, medium_max));
// small class count + medium class count + 1 for large <= span_effective_size

pub const span_alignment = log2(span_size);
pub const span_lower_mask: usize = span_size - 1;
pub const span_upper_mask: usize = ~span_lower_mask;

pub const zero_offset = 0;

pub const small_granularity = 16;
pub const small_granularity_shift = log2(small_granularity);
pub const small_max = 2048;
pub const small_class_count = small_max / small_granularity;

pub const medium_granularity = 256;
pub const medium_granularity_shift = log2(medium_granularity);
// fit at least 2 medium allocs in one span
pub const medium_max = span_effective_size / 2 - ((span_effective_size / 2) % medium_granularity);
pub const medium_class_count = (medium_max - small_max) / medium_granularity;

pub const large_class_count = 64;
pub const large_max = large_class_count * span_size - span_header_size;

pub const size_class_count = small_class_count + medium_class_count + 1;

pub const small_size_classes = generateSmallSizeClasses();
pub const medium_size_classes = generateMediumSizeClasses();
pub const aligned_size_classes = generateAlignedSizeClasses();

pub const span_class = SizeClass{
    .block_max = 1,
    .block_size = span_effective_size,
    .class_idx = small_class_count + medium_class_count,
    .aligned = false,
};

fn generateSmallSizeClasses() [small_class_count]SizeClass {
    var size_classes: [small_class_count]SizeClass = undefined;

    for (0..small_class_count) |i| {
        size_classes[i].block_size = (i + 1) * small_granularity;
        size_classes[i].block_max = span_effective_size / size_classes[i].block_size;
        size_classes[i].class_idx = i;
        size_classes[i].aligned = false;
    }

    mergeSizeClasses(&size_classes);

    assert(size_classes[0].block_size == small_granularity);
    assert(size_classes[size_classes.len - 1].block_size == small_max);

    return size_classes;
}

fn generateMediumSizeClasses() [medium_class_count]SizeClass {
    var size_classes: [medium_class_count]SizeClass = undefined;

    for (0..medium_class_count) |i| {
        size_classes[i].block_size = small_max + (i + 1) * medium_granularity;
        size_classes[i].block_max = span_effective_size / size_classes[i].block_size;
        size_classes[i].class_idx = small_class_count + i;
        size_classes[i].aligned = false;
    }

    mergeSizeClasses(&size_classes);

    assert(size_classes[0].block_size == small_max + medium_granularity);
    assert(size_classes[size_classes.len - 1].block_size == medium_max);
    assert(size_classes[size_classes.len - 1].block_max > 1);

    return size_classes;
}

fn generateAlignedSizeClasses() [aligned_class_count]SizeClass {
    var size_classes: [aligned_class_count]SizeClass = undefined;

    for (0..aligned_class_count) |i| {
        const block_size = 1 << (i + aligned_spans_offset);

        size_classes[i].block_size = block_size;
        size_classes[i].block_max = (span_size - block_size) / block_size;
        size_classes[i].class_idx = i;
        size_classes[i].aligned = true;
    }

    return size_classes;
}

// merge size classes with equal block count to higher size
fn mergeSizeClasses(size_classes: []SizeClass) void {
    var i = size_classes.len - 1;
    while (i > 0) : (i -= 1) {
        if (size_classes[i].block_max == size_classes[i - 1].block_max) {
            // need to maintain power of 2 classes for alignment
            if (utils.isPowerOfTwo(size_classes[i - 1].block_size)) continue;

            size_classes[i - 1].block_size = size_classes[i].block_size;
            size_classes[i - 1].class_idx = size_classes[i].class_idx;
        }
    }
}
