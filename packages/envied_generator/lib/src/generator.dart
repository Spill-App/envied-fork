import 'dart:io' show Platform;

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:envied/envied.dart';
import 'package:envied_generator/src/build_options.dart';
import 'package:envied_generator/src/env_val.dart';
import 'package:envied_generator/src/extensions.dart';
import 'package:envied_generator/src/generate_field.dart';
import 'package:envied_generator/src/generate_field_encrypted.dart';
import 'package:envied_generator/src/load_envs.dart';
import 'package:recase/recase.dart';
import 'package:source_gen/source_gen.dart';

/// Generate code for classes annotated with the `@Envied()`.
///
/// Will throw an [InvalidGenerationSourceError] if the annotated
/// element is not a [ClassElement2].
final class EnviedGenerator extends GeneratorForAnnotation<Envied> {
  const EnviedGenerator(this._buildOptions);

  final BuildOptions _buildOptions;

  @override
  Future<String> generateForAnnotatedElement(
    Element2 element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) async {
    // Synchronously throw if the element is not a class, so test matchers can catch it
    if (element is! ClassElement2) {
      throw InvalidGenerationSourceError(
        '`@Envied` can only be used on classes.',
        element: element,
      );
    }
    // Synchronously throw if any field has an unsupported type
    final classElement = element;
    for (final field in classElement.fields2) {
      if (_typeChecker(EnviedField).hasAnnotationOf(field)) {
        // Synchronously throw if the field type is InvalidType
        if (field.type is InvalidType) {
          throw InvalidGenerationSourceError(
            'Envied requires types to be explicitly declared. `${field.name3}` does not declare a type.',
            element: field,
          );
        }
        String typeStr = field.type.typeNameDisplayString;
        const supportedTypes = ['int', 'double', 'num', 'bool', 'Uri', 'DateTime', 'String', 'dynamic'];
        // Determine if obfuscation is enabled for this field or class
        final fieldObfuscate = field.metadata2.annotations.any((a) =>
            a.element2?.displayName == 'EnviedField' &&
            ConstantReader(a.computeConstantValue()).read('obfuscate').literalValue == true);
        final classObfuscate = annotation.read('obfuscate').literalValue == true;
        final isObfuscated = fieldObfuscate || classObfuscate;
        if (!supportedTypes.contains(typeStr) && !field.type.isDartEnum) {
          if (isObfuscated) {
            throw InvalidGenerationSourceError(
              'Obfuscated envied can only handle types such as `int`, `double`, `num`, `bool`, `Uri`, `DateTime`, `Enum` and `String`. Type `$typeStr` is not one of them.',
              element: field,
            );
          } else {
            throw InvalidGenerationSourceError(
              'Envied can only handle types such as `int`, `double`, `num`, `bool`, `Uri`, `DateTime`, `Enum` and `String`. Type `$typeStr` is not one of them.',
              element: field,
            );
          }
        }
      }
    }

    final Iterable<ConstantReader> enviedAnnotations = element.metadata2.annotations
        .where((ElementAnnotation annotation) => annotation.element2?.displayName == 'Envied')
        .map((ElementAnnotation annotation) => ConstantReader(annotation.computeConstantValue()));

    final bool multipleAnnotations = enviedAnnotations.length > 1;

    final StringBuffer generatedClassesAltogether = StringBuffer();

    for (final ConstantReader reader in enviedAnnotations) {
      generatedClassesAltogether.writeln(
        await _generateClassForEnviedAnnotation(
          element: element,
          annotation: reader,
          buildStep: buildStep,
          multipleAnnotations: multipleAnnotations,
        ),
      );
    }

    final String? generatedFrom = _buildOptions.override == true && _buildOptions.path?.isNotEmpty == true
        ? _buildOptions.path
        : annotation.read('path').literalValue as String?;

    final String ignore = '// coverage:ignore-file\n'
        '// ignore_for_file: type=lint\n'
        '// generated_from: $generatedFrom';

    return '$ignore\n$generatedClassesAltogether';
  }

  Future<String> _generateClassForEnviedAnnotation({
    required Element2 element,
    required ConstantReader annotation,
    required BuildStep buildStep,
    bool multipleAnnotations = false,
  }) async {
    final enviedEl = element;
    if (enviedEl is! ClassElement2) {
      throw InvalidGenerationSourceError(
        '`@Envied` can only be used on classes.',
        element: enviedEl,
      );
    }

    final Envied config = Envied(
      path: _buildOptions.override == true && _buildOptions.path?.isNotEmpty == true
          ? _buildOptions.path
          : annotation.read('path').literalValue as String?,
      requireEnvFile: annotation.read('requireEnvFile').literalValue as bool? ?? false,
      name: annotation.read('name').literalValue as String?,
      obfuscate: annotation.read('obfuscate').literalValue as bool,
      allowOptionalFields: annotation.read('allowOptionalFields').literalValue as bool? ?? false,
      environment: annotation.read('environment').literalValue as bool? ?? false,
      useConstantCase: annotation.read('useConstantCase').literalValue as bool? ?? false,
      interpolate: annotation.read('interpolate').literalValue as bool? ?? true,
      rawStrings: annotation.read('rawStrings').literalValue as bool? ?? false,
      randomSeed: annotation.read('randomSeed').literalValue as int?,
    );

    final Map<String, EnvVal> envs = await loadEnvs(config.path, (String error) {
      if (config.requireEnvFile) {
        throw InvalidGenerationSourceError(
          error,
          element: enviedEl,
        );
      }
    });

    final DartEmitter emitter = DartEmitter(useNullSafetySyntax: true);

    final Class cls = Class(
      (ClassBuilder classBuilder) => classBuilder
        ..modifier = ClassModifier.final$
        ..name = '_${config.name ?? enviedEl.name3}'
        ..implements.addAll([
          if (multipleAnnotations) refer(enviedEl.name3 ?? ''),
        ])
        ..fields.addAll(
          enviedEl.fields2.where((FieldElement2 field) => _typeChecker(EnviedField).hasAnnotationOf(field)).expand(
                (FieldElement2 field) => _generateFields(
                  field: field,
                  config: config,
                  envs: envs,
                  multipleAnnotations: multipleAnnotations,
                ),
              ),
        ),
    );

    String classOutput = cls.accept(emitter).toString();
    // If code_builder emits nothing or only whitespace for an empty class, emit it manually
    if (classOutput.replaceAll(RegExp(r'\s+'), '').isEmpty) {
      final className = '_${config.name ?? enviedEl.name3}';
      classOutput = 'final class $className {}\n';
    }
    return classOutput;
  }

  static TypeChecker _typeChecker(Type type) => TypeChecker.fromRuntime(type);

  static Iterable<Field> _generateFields({
    required FieldElement2 field,
    required Envied config,
    required Map<String, EnvVal> envs,
    bool multipleAnnotations = false,
  }) {
    final DartObject? dartObject = _typeChecker(EnviedField).firstAnnotationOf(field);

    final ConstantReader reader = ConstantReader(dartObject);

    late String varName;

    final bool environment = reader.read('environment').literalValue as bool? ?? config.environment;

    final bool useConstantCase = reader.read('useConstantCase').literalValue as bool? ?? config.useConstantCase;

    if (reader.read('varName').literalValue == null) {
      varName = useConstantCase ? (field.name3?.constantCase ?? field.name3 ?? '') : field.name3 ?? '';
    } else {
      varName = reader.read('varName').literalValue as String;
    }

    final Object? defaultValue = reader.read('defaultValue').literalValue;

    late final EnvVal? varValue;

    if (environment) {
      final String? envKey = envs[varName]?.raw;
      if (envKey == null) {
        throw InvalidGenerationSourceError(
          'Expected to find an .env entry with a key of `$varName` for field `${field.name3}` but none was found.',
          element: field,
        );
      }
      final String? env = Platform.environment[envKey];
      final bool isNullable =
          config.allowOptionalFields && field.type.nullabilitySuffix.toString() == 'NullabilitySuffix.question';
      if (env == null) {
        if (!config.allowOptionalFields || !isNullable) {
          throw InvalidGenerationSourceError(
            'Expected to find an System environment variable named `$envKey` for field `${field.name3}` but no value was found.',
            element: field,
          );
        } else {
          varValue = null;
        }
      } else {
        varValue = EnvVal(raw: env);
      }
    } else if (envs.containsKey(varName)) {
      varValue = envs[varName];
    } else if (Platform.environment.containsKey(varName)) {
      varValue = EnvVal(raw: Platform.environment[varName]!);
    } else {
      varValue = defaultValue != null ? EnvVal(raw: defaultValue.toString()) : null;
    }

    if (field.type is InvalidType) {
      throw InvalidGenerationSourceError(
        'Envied requires types to be explicitly declared. `${field.name3}` does not declare a type.',
        element: field,
      );
    }

    final bool optional = reader.read('optional').literalValue as bool? ?? config.allowOptionalFields;

    final bool interpolate = reader.read('interpolate').literalValue as bool? ?? config.interpolate;

    final bool rawString = reader.read('rawString').literalValue as bool? ?? config.rawStrings;

    // Throw if value is null but the field is not nullable
    bool isNullable = field.type is DynamicType || field.type.nullabilitySuffix == NullabilitySuffix.question;
    if (varValue == null && !(optional && isNullable)) {
      throw InvalidGenerationSourceError(
        'Environment variable not found for field `${field.name3}`.',
        element: field,
      );
    }

    return reader.read('obfuscate').literalValue as bool? ?? config.obfuscate
        ? generateFieldsEncrypted(
            field,
            interpolate ? varValue?.interpolated : varValue?.raw,
            allowOptional: optional,
            randomSeed: (reader.read('randomSeed').literalValue as int?) ?? config.randomSeed,
            multipleAnnotations: multipleAnnotations,
          )
        : generateFields(
            field,
            interpolate ? varValue?.interpolated : varValue?.raw,
            allowOptional: optional,
            rawString: rawString,
            multipleAnnotations: multipleAnnotations,
          );
  }
}
