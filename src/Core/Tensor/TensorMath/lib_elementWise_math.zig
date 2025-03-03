//! These operations are applied to each element of the tensor independently.
//!
//!    Arithmetic Operations: Addition, subtraction, multiplication, division, modulo, power.
//!    Trigonometric Functions: Sine, cosine, tangent, arcsine, arccosine, etc.
//!    Exponential and Logarithmic Functions: Exponentiation, natural log, log base 10.
//!    Rounding Functions: Floor, ceil, round, truncation.

const std = @import("std");
const Tensor = @import("tensor").Tensor; // Import Tensor type
const pkg_allocator = @import("pkgAllocator").allocator;
const TensorMathError = @import("errorHandler").TensorMathError;
const TensorError = @import("errorHandler").TensorError;
const TypeError = @import("errorHandler").TypeError;
const Converter = @import("typeC");
const ArchitectureError = @import("errorHandler").ArchitectureError;

/// Function that add the bias for all the features in the tensor
pub fn add_bias(comptime T: anytype, tensor: *Tensor(T), bias: *Tensor(T)) !void {
    // Checks:
    if (tensor.size == 0) {
        return TensorError.EmptyTensor;
    }
    if (bias.size == 0) {
        return TensorError.EmptyTensor;
    }
    if (bias.shape.len != 4) {
        return TensorMathError.InputTensorsWrongShape;
    }
    const len = bias.shape[3];
    if (len != tensor.shape[tensor.shape.len - 1]) {
        return TensorMathError.InputTensorDimensionMismatch;
    }

    // Instead of using threads, just do it directly
    var index: usize = 0;
    while (index < tensor.size) : (index += len) {
        for (0..len) |i| {
            tensor.data[index + i] += bias.data[i];
        }
    }
}

// -----------------------------------------------
// --------------------- SUM ---------------------
// -----------------------------------------------
// --------- standard SUM
///Returns a Tensor with the same shape pf t1 and t2, where each element --> out[location] = t1[location] + t2[location]
pub fn sum_tensors(comptime inputType: anytype, comptime outputType: anytype, t1: *Tensor(inputType), t2: *Tensor(inputType)) !Tensor(outputType) {
    // CHECKS:
    if (t1.size != t2.size) return TensorMathError.InputTensorDifferentSize;

    if (@bitSizeOf(outputType) <= 16) { // quantized
        if (@bitSizeOf(outputType) <= (@bitSizeOf(inputType) * 2)) return TensorMathError.TooSmallOutputType;
    } else { // non-quant
        if (@bitSizeOf(outputType) < @bitSizeOf(inputType)) return TensorMathError.TooSmallOutputType;
    }

    // Create output tensor initialized to zero
    var out_tensor = try Tensor(outputType).fromShape(t1.allocator, t2.shape);

    try lean_sum_tensors(inputType, outputType, t1, t2, &out_tensor);

    return out_tensor;
}
// --------- lean SUM
pub inline fn lean_sum_tensors(comptime inputType: anytype, comptime outputType: anytype, t1: *Tensor(inputType), t2: *Tensor(inputType), outputTensor: *Tensor(outputType)) !void {
    for (0..t1.data.len) |i| {
        outputTensor.data[i] = t1.data[i] + t2.data[i];
    }
}

/// Returns a Tensor with the same shape as the input tensors, where each element is the sum of all tensors at that location
pub fn sum_tensor_list(comptime inputType: anytype, comptime outputType: anytype, tensors: []const *Tensor(inputType)) !Tensor(outputType) {
    if (tensors.len == 0) return TensorMathError.EmptyTensorList;
    if (tensors.len == 1) {
        var out_tensor = try Tensor(outputType).fromShape(tensors[0].allocator, tensors[0].shape);
        for (0..tensors[0].data.len) |i| {
            out_tensor.data[i] = tensors[0].data[i];
        }
        return out_tensor;
    }

    // Use first tensor as reference for size and shape checks
    const ref_tensor = tensors[0];

    // Check all tensors have same size
    for (tensors[1..]) |t| {
        if (t.size != ref_tensor.size) return TensorMathError.InputTensorDifferentSize;
    }

    if (@bitSizeOf(outputType) <= 16) { // quantized
        if (@bitSizeOf(outputType) <= (@bitSizeOf(inputType) * 2)) return TensorMathError.TooSmallOutputType;
    } else { // non-quant
        if (@bitSizeOf(outputType) < @bitSizeOf(inputType)) return TensorMathError.TooSmallOutputType;
    }

    var out_tensor = try Tensor(outputType).fromShape(ref_tensor.allocator, ref_tensor.shape);
    try lean_sum_tensor_list(inputType, outputType, tensors, &out_tensor);

    return out_tensor;
}

pub inline fn lean_sum_tensor_list(comptime inputType: anytype, comptime outputType: anytype, tensors: []const *Tensor(inputType), outputTensor: *Tensor(outputType)) !void {
    if (tensors.len == 0) return TensorMathError.EmptyTensorList;

    // Initialize output with first tensor
    for (0..tensors[0].data.len) |i| {
        outputTensor.data[i] = tensors[0].data[i];
    }

    // Add remaining tensors
    for (tensors[1..]) |t| {
        for (0..t.data.len) |i| {
            outputTensor.data[i] += t.data[i];
        }
    }
}

/// Performs element-wise binary subtraction with Numpy-style broadcasting support
pub fn sub_tensors(comptime inputType: anytype, comptime outputType: anytype, t1: *Tensor(inputType), t2: *Tensor(inputType)) !Tensor(outputType) {
    // CHECKS:
    if (@TypeOf(outputType) == @TypeOf(inputType)) {
        // If input and output are same type, no check needed
    } else {
        if (@bitSizeOf(outputType) <= 16) { //quantized
            if (@bitSizeOf(outputType) <= (@bitSizeOf(inputType) * 2)) return TensorMathError.TooSmallOutputType;
        } else { //non-quant
            if (@bitSizeOf(outputType) < @bitSizeOf(inputType)) return TensorMathError.TooSmallOutputType;
        }
    }

    // Handle broadcasting
    const rank1 = t1.shape.len;
    const rank2 = t2.shape.len;
    const max_rank = @max(rank1, rank2);

    // Pad shapes with 1s for broadcasting
    var shape1 = try pkg_allocator.alloc(usize, max_rank);
    defer pkg_allocator.free(shape1);
    var shape2 = try pkg_allocator.alloc(usize, max_rank);
    defer pkg_allocator.free(shape2);

    // Initialize with 1s
    @memset(shape1, 1);
    @memset(shape2, 1);

    // Copy original shapes from right to left
    var i: usize = 0;
    while (i < rank1) : (i += 1) {
        shape1[max_rank - rank1 + i] = t1.shape[i];
    }
    i = 0;
    while (i < rank2) : (i += 1) {
        shape2[max_rank - rank2 + i] = t2.shape[i];
    }

    // Verify shapes are compatible for broadcasting
    var out_shape = try pkg_allocator.alloc(usize, max_rank);
    errdefer pkg_allocator.free(out_shape);

    for (0..max_rank) |dim| {
        if (shape1[dim] != shape2[dim] and shape1[dim] != 1 and shape2[dim] != 1) {
            return TensorMathError.IncompatibleBroadcastShapes;
        }
        out_shape[dim] = @max(shape1[dim], shape2[dim]);
    }

    // Calculate total size and strides
    var total_size: usize = 1;
    var strides1 = try pkg_allocator.alloc(usize, max_rank);
    defer pkg_allocator.free(strides1);
    var strides2 = try pkg_allocator.alloc(usize, max_rank);
    defer pkg_allocator.free(strides2);
    var out_strides = try pkg_allocator.alloc(usize, max_rank);
    defer pkg_allocator.free(out_strides);

    // Calculate strides from right to left
    var stride: usize = 1;
    i = max_rank;
    while (i > 0) {
        i -= 1;
        out_strides[i] = stride;
        strides1[i] = if (shape1[i] > 1) stride else 0;
        strides2[i] = if (shape2[i] > 1) stride else 0;
        stride *= out_shape[i];
    }
    total_size = stride;

    std.debug.print("\nshape1: {any}, strides1: {any}", .{ shape1, strides1 });
    std.debug.print("\nshape2: {any}, strides2: {any}", .{ shape2, strides2 });
    std.debug.print("\nout_shape: {any}, out_strides: {any}", .{ out_shape, out_strides });

    // Allocate output tensor
    var out_data = try pkg_allocator.alloc(outputType, total_size);
    errdefer pkg_allocator.free(out_data);

    // Perform subtraction with broadcasting
    var indices = try pkg_allocator.alloc(usize, max_rank);
    defer pkg_allocator.free(indices);
    @memset(indices, 0);

    i = 0;
    while (i < total_size) : (i += 1) {
        // Calculate indices for current position
        var temp = i;
        for (0..max_rank) |dim| {
            const idx = max_rank - 1 - dim;
            indices[idx] = temp / out_strides[idx];
            temp = temp % out_strides[idx];
        }

        // Calculate input indices considering broadcasting
        var idx1: usize = 0;
        var idx2: usize = 0;

        // For same shape tensors, use the same index calculation
        if (std.mem.eql(usize, shape1, shape2)) {
            idx1 = i;
            idx2 = i;
        } else {
            // For broadcasting case
            for (0..max_rank) |dim| {
                const pos = indices[dim];
                // For t1: if dimension is 1, don't increment index (broadcasting)
                if (shape1[dim] > 1) {
                    idx1 += pos * strides1[dim];
                }
                // For t2: if dimension is 1, don't increment index (broadcasting)
                if (shape2[dim] > 1) {
                    const t2_pos = pos % shape2[dim];
                    idx2 += t2_pos * strides2[dim];
                }
            }
        }

        // Perform subtraction: t1 - t2
        const val1 = t1.data[idx1];
        const val2 = t2.data[idx2];
        out_data[i] = val1 - val2;
        std.debug.print("\nFinal: idx1={}, val1={}, idx2={}, val2={}, result={}", .{ idx1, val1, idx2, val2, out_data[i] });
    }

    return Tensor(outputType){
        .data = out_data,
        .shape = out_shape,
        .size = total_size,
        .allocator = &pkg_allocator,
    };
}

// -----------------------------------------------
// --------------------- MUL ---------------------
// -----------------------------------------------
// --------- standard MUL
pub fn mul(comptime T: anytype, lhs: *Tensor(T), rhs: *Tensor(T)) !Tensor(T) {
    if (lhs.size != rhs.size) {
        return TensorError.MismatchedShape;
    }

    const allocator = lhs.allocator;
    var result = try Tensor(T).fromShape(allocator, lhs.shape);

    mul_lean(T, lhs, rhs, &result);

    return result;
}
// --------- lean MUL
pub inline fn mul_lean(comptime T: anytype, lhs: *Tensor(T), rhs: *Tensor(T), result: *Tensor(T)) void {
    for (0..lhs.size) |i| {
        result.data[i] = lhs.data[i] * rhs.data[i];
    }
}

// -----------------------------------------------
// --------------------- DIV ---------------------
// -----------------------------------------------
// --------- standard DIV
/// Performs Element-wise binary division of two tensors.
pub fn div(comptime T: anytype, lhs: *Tensor(T), rhs: *Tensor(T)) !Tensor(T) {
    if (lhs.size != rhs.size) {
        return TensorError.MismatchedShape;
    }

    const allocator = lhs.allocator;
    var result = try Tensor(T).fromShape(allocator, lhs.shape);

    div_lean(T, lhs, rhs, &result);

    return result;
}
// --------- lean DIV
pub inline fn div_lean(comptime T: anytype, lhs: *Tensor(T), rhs: *Tensor(T), result: *Tensor(T)) void {
    for (0..lhs.size) |i| {
        result.data[i] = lhs.data[i] / rhs.data[i];
    }
}

// -----------------------------------------------
// --------------------- TANH --------------------
// -----------------------------------------------
// --------- standard TANH
/// Compute element-wise the hyperbolic tangent of the given tensor.
pub fn tanh(comptime T: anytype, input: *Tensor(T)) !Tensor(T) {
    // Verify that T is among the supported types:
    // tensor(double), tensor(float), tensor(float16)
    comptime if (!(std.meta.eql(T, f64) or std.meta.eql(T, f32) or std.meta.eql(T, f16))) {
        @compileError("Unsupported type in tanh_lean");
    };

    // Allocating output tensor with the same shape of the input
    var result = try Tensor(T).fromShape(input.allocator, input.shape);

    tanh_lean(T, input, &result);

    return result;
}

// --------- lean TANH
pub inline fn tanh_lean(comptime T: anytype, input: *Tensor(T), result: *Tensor(T)) void {
    // Compute tanh(x) for each element of the tensor
    for (0..input.size) |i| {
        result.data[i] = std.math.tanh(input.data[i]);
    }
}

// -----------------------------------------------
// --------------------- CEIL --------------------
// -----------------------------------------------
// --------- standard CEIL
/// Compute element-wise the ceil of the given tensor.
/// If x is integral, +0, -0, NaN, or infinite, x itself is returned.
pub fn ceil(comptime T: anytype, input: *Tensor(T)) !Tensor(T) {
    // Verify that T is among the supported types:
    // tensor(double), tensor(float), tensor(float16)
    comptime if (!(std.meta.eql(T, f64) or std.meta.eql(T, f32) or std.meta.eql(T, f16))) {
        @compileError("Unsupported type in ceil_lean");
    };

    // Allocate output tensor with the same shape as the input
    var result = try Tensor(T).fromShape(input.allocator, input.shape);

    // Perform element-wise ceil computation
    ceil_lean(T, input, &result);

    return result;
}

// --------- lean CEIL
pub inline fn ceil_lean(comptime T: anytype, input: *Tensor(T), result: *Tensor(T)) void {
    for (0..input.size) |i| {
        const x = input.data[i];
        if (std.math.isNan(x) or std.math.isInf(x)) {
            result.data[i] = x;
        } else {
            result.data[i] = @ceil(x);
        }
    }
}
