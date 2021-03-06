/*
 * # Copyright (c) 2016-2017 The Khronos Group Inc.
 * # Copyright (c) 2016 Alexey Knyazev
 * #
 * # Licensed under the Apache License, Version 2.0 (the "License");
 * # you may not use this file except in compliance with the License.
 * # You may obtain a copy of the License at
 * #
 * #     http://www.apache.org/licenses/LICENSE-2.0
 * #
 * # Unless required by applicable law or agreed to in writing, software
 * # distributed under the License is distributed on an "AS IS" BASIS,
 * # WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * # See the License for the specific language governing permissions and
 * # limitations under the License.
 */

/*
  TODO
  points - warn on duplicates
  lines - degenerate (v(2n)=v(2n+1)), duplicates (incl. reversed)
  line_loop, line_stripe - degenerate (v(n)=v(n+1)),
  triangles - degenerate (v1=v2 | v2=v3 | v1=v3), duplicates (order-aware)
  triangle_strip - degenerate (v1=v2=v3), duplicates (order-aware)
  triangle_fan - ???
 */

/*
  TODO
  warn when there're more than two equal consequential animation frames
  (across all outputs)
 */

/*
  TODO
  warn when interpolation may produce zero-length quaternions
 */

library gltf.data_access.validate_accessors_data;

import 'dart:math';
import 'package:gltf/gltf.dart';
import 'package:gltf/src/base/gltf_property.dart';
import 'package:gltf/src/gl.dart' as gl;
import 'package:vector_math/vector_math.dart';

void validateAccessorsData(Gltf gltf, Context context) {
  context.path
    ..clear()
    ..add(ACCESSORS);

  final matrix = Matrix4.zero();

  final doubleMins = List<double>(16);
  final doubleMaxs = List<double>(16);

  final intMins = List<int>(16);
  final intMaxs = List<int>(16);

  final numInvalidMins = List<int>(16);
  final numInvalidMaxs = List<int>(16);

  final triangle = List<int>(3);

  gltf.accessors.forEachWithIndices((i, accessor) {
    // Skip broken accessors
    if (accessor.type == null ||
        accessor.componentType == -1 ||
        accessor.count == -1) {
      return;
    }

    if (accessor.isXyzSign && accessor.components != 4) {
      return;
    }

    if (accessor.isUnit && accessor.components > 4) {
      return;
    }

    if (accessor.containsCubicSpline && accessor.count.remainder(3) != 0) {
      return;
    }

    // Skip empty accessors
    if (accessor.bufferView == null && accessor.sparse == null) {
      return;
    }

    context.path.add(i.toString());

    if (accessor.sparse != null) {
      // Check sparse indices
      final view = accessor.sparse.indicesTypedView;
      if (view != null) {
        var index = 0;
        var lastValue = -1;
        for (final value in view) {
          if (lastValue != -1 && value <= lastValue) {
            context.addIssue(DataError.accessorSparseIndicesNonIncreasing,
                args: [index, value, lastValue]);
          }
          if (value >= accessor.count) {
            context.addIssue(DataError.accessorSparseIndexOob,
                args: [index, value, accessor.count]);
          }
          lastValue = value;
          ++index;
        }
      }
    }

    final components = accessor.components;

    var sum = 0.0;
    var index = 0;
    var componentIndex = 0;

    numInvalidMins.fillRange(0, 16, 0);
    numInvalidMaxs.fillRange(0, 16, 0);

    // 0: in; 1: value; 2: out
    var cubicSplineState = 0;

    final iterator = gltf.accessors[i].getElements().iterator;

    var hasNext = iterator.moveNext();

    // Empty accessor
    if (!hasNext) {
      context.path.removeLast();
      return;
    }

    // Validation of float and integer data is partly
    // duplicated to avoid extra polymorphism
    if (accessor.componentType == gl.FLOAT) {
      var lastValue = -1.0;

      // Clean min/max arrays to not re-use values from previous accessors
      if (accessor.min != null) {
        doubleMins.fillRange(0, 16, double.nan);
      }

      if (accessor.max != null) {
        doubleMaxs.fillRange(0, 16, double.nan);
      }

      while (hasNext) {
        final double value = iterator.current;

        // Min and max checks are performed on each component value,
        // other checks wait until all components are provided

        if (value.isNaN || value.isInfinite) {
          context.addIssue(DataError.accessorInvalidFloat, args: [index]);
        } else {
          // Check that there're no out-of-bounds values

          if (accessor.min != null) {
            if (value < accessor.min[componentIndex]) {
              ++numInvalidMins[componentIndex];
            }

            if (doubleMins[componentIndex].isNaN ||
                doubleMins[componentIndex] > value) {
              doubleMins[componentIndex] = value;
            }
          }

          if (accessor.max != null) {
            if (value > accessor.max[componentIndex]) {
              ++numInvalidMaxs[componentIndex];
            }

            if (doubleMaxs[componentIndex].isNaN ||
                doubleMaxs[componentIndex] < value) {
              doubleMaxs[componentIndex] = value;
            }
          }

          if (accessor.usage == AccessorUsage.AnimationInput) {
            if (value < 0.0) {
              context.addIssue(DataError.accessorAnimationInputNegative,
                  args: [index, value]);
            } else {
              if (lastValue != -1.0 && value <= lastValue) {
                context.addIssue(DataError.accessorAnimationInputNonIncreasing,
                    args: [index, value, lastValue]);
              }
              lastValue = value;
            }
          } else if (accessor.usage == AccessorUsage.IBM) {
            matrix.storage[componentIndex] = value;
          } else if (accessor.isUnit &&
              !(accessor.isXyzSign && componentIndex == 3) &&
              !(accessor.containsCubicSpline && cubicSplineState != 1)) {
            sum += value * value;
          }
        }

        if (++componentIndex == components) {
          if (accessor.usage == AccessorUsage.IBM) {
            if (!isTrsDecomposable(matrix)) {
              context.addIssue(DataError.indecomposableMatrix, args: [index]);
            }
          } else if (accessor.isUnit &&
              !(accessor.containsCubicSpline && cubicSplineState != 1)) {
            if ((sum - 1.0).abs() > 0.0005) {
              context.addIssue(DataError.accessorNonUnit,
                  args: [index, sqrt(sum)]);
            }
            sum = 0.0;

            if (accessor.isXyzSign && value != 1.0 && value != -1.0) {
              context.addIssue(DataError.accessorInvalidSign,
                  args: [index, value]);
            }
          }

          if (accessor.containsCubicSpline && ++cubicSplineState == 3) {
            cubicSplineState = 0;
          }

          componentIndex = 0;
        }

        ++index;
        hasNext = iterator.moveNext();
      }

      if (accessor.min != null) {
        for (var i = 0; i < components; ++i) {
          if (accessor.min[i] != doubleMins[i]) {
            context.addIssue(DataError.accessorMinMismatch,
                name: '$MIN/$i', args: [accessor.min[i], doubleMins[i]]);

            if (numInvalidMins[i] > 0) {
              context.addIssue(DataError.accessorElementOutOfMinBound,
                  name: '$MIN/$i',
                  args: [numInvalidMins[i], accessor.min[componentIndex]]);
            }
          }
        }
      }

      if (accessor.max != null) {
        for (var i = 0; i < components; ++i) {
          if (accessor.max[i] != doubleMaxs[i]) {
            context.addIssue(DataError.accessorMaxMismatch,
                name: '$MAX/$i', args: [accessor.max[i], doubleMaxs[i]]);
          }

          if (numInvalidMaxs[i] > 0) {
            context.addIssue(DataError.accessorElementOutOfMaxBound,
                name: '$MAX/$i',
                args: [numInvalidMaxs[i], accessor.max[componentIndex]]);
          }
        }
      }
    } else {
      // Accessor with integer data

      // Temp vars for indices validation
      var maxVertexIndex = -1;
      var modesMask = 0;
      var vertIndex = 0;
      var degenerateTris = 0;

      if (accessor.usage == AccessorUsage.PrimitiveIndices) {
        // Find primitive modes and min number of vertices
        // that are used by this index buffer
        for (final mesh in gltf.meshes) {
          if (mesh.primitives == null) {
            continue;
          }

          for (final primitive in mesh.primitives) {
            if (primitive.indices == accessor) {
              if (primitive.mode != -1) {
                modesMask |= 1 << primitive.mode;
              }

              if (primitive.vertexCount != -1 &&
                  (maxVertexIndex == -1 ||
                      maxVertexIndex > primitive.vertexCount)) {
                maxVertexIndex = primitive.vertexCount;
              }
            }
          }
        }
        --maxVertexIndex;
      }

      while (hasNext) {
        final int value = iterator.current;

        if (accessor.min != null) {
          if (value < accessor.min[componentIndex]) {
            ++numInvalidMins[componentIndex];
          }

          if (index < components || intMins[componentIndex] > value) {
            intMins[componentIndex] = value;
          }
        }

        if (accessor.max != null) {
          if (value > accessor.max[componentIndex]) {
            ++numInvalidMaxs[componentIndex];
          }

          if (index < components || intMaxs[componentIndex] < value) {
            intMaxs[componentIndex] = value;
          }
        }

        if (accessor.usage == AccessorUsage.PrimitiveIndices) {
          if (value > maxVertexIndex) {
            context.addIssue(DataError.accessorIndexOob,
                args: [index, value, maxVertexIndex]);
          }

          if (_isTriangles(modesMask)) {
            triangle[vertIndex] = value;
            if (++vertIndex == 3) {
              vertIndex = 0;
              if (triangle[0] == triangle[1] ||
                  triangle[1] == triangle[2] ||
                  triangle[2] == triangle[0]) {
                ++degenerateTris;
              }
            }
          }
        } else if (accessor.isUnit &&
            !(accessor.containsCubicSpline && cubicSplineState != 1)) {
          final normalizedValue = accessor.normalizeValue(value);
          sum += normalizedValue * normalizedValue;
        }

        if (++componentIndex == components) {
          if (accessor.isUnit &&
              !(accessor.containsCubicSpline && cubicSplineState != 1)) {
            if ((sum - 1.0).abs() > 0.0005) {
              context.addIssue(DataError.accessorNonUnit,
                  args: [index, sqrt(sum)]);
            }
            sum = 0.0;
          }

          if (accessor.containsCubicSpline && ++cubicSplineState == 3) {
            cubicSplineState = 0;
          }

          componentIndex = 0;
        }

        ++index;
        hasNext = iterator.moveNext();
      }

      if (accessor.min != null) {
        for (var i = 0; i < components; ++i) {
          if (accessor.min[i] != intMins[i]) {
            context.addIssue(DataError.accessorMinMismatch,
                name: '$MIN/$i', args: [accessor.min[i], intMins[i]]);
          }

          if (numInvalidMins[i] > 0) {
            context.addIssue(DataError.accessorElementOutOfMinBound,
                name: '$MIN/$i',
                args: [numInvalidMins[i], accessor.min[componentIndex]]);
          }
        }
      }

      if (accessor.max != null) {
        for (var i = 0; i < components; ++i) {
          if (accessor.max[i] != intMaxs[i]) {
            context.addIssue(DataError.accessorMaxMismatch,
                name: '$MAX/$i', args: [accessor.max[i], intMaxs[i]]);
          }

          if (numInvalidMaxs[i] > 0) {
            context.addIssue(DataError.accessorElementOutOfMaxBound,
                name: '$MAX/$i',
                args: [numInvalidMaxs[i], accessor.max[componentIndex]]);
          }
        }
      }

      if (degenerateTris > 0) {
        context.addIssue(DataError.accessorIndexTriangleDegenerate,
            args: [degenerateTris]);
      }
    }

    context.path.removeLast();
  });
}

bool _isPoints(int mask) => mask & 1 == 1;
bool _isLines(int mask) => mask & 2 == 2;
bool _isLineLoop(int mask) => mask & 4 == 4;
bool _isLineStrip(int mask) => mask & 8 == 8;
bool _isTriangles(int mask) => mask & 16 == 16;
bool _isTriangleStrip(int mask) => mask & 32 == 32;
bool _isTriangleFan(int mask) => mask & 64 == 64;
