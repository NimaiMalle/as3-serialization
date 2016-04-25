package util
{
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.utils.getDefinitionByName;
	import flash.utils.getQualifiedClassName;
	
	import org.as3commons.reflect.Accessor;
	import org.as3commons.reflect.Constant;
	import org.as3commons.reflect.Field;
	import org.as3commons.reflect.IMetadataContainer;
	import org.as3commons.reflect.Metadata;
	import org.as3commons.reflect.MetadataArgument;
	import org.as3commons.reflect.Type;
	
	import service.ErrorManager;
	
	public class Serialization
	{
		public static const TYPE_FIELD:String = "_type";
		
		public static const ARRAY_MERGE:String = "MERGE";
		public static const ARRAY_REPLACE:String = "REPLACE";
		
		private var _defaultPackages:Vector.<String> = new Vector.<String>();
		private var _activeVariants:Vector.<String> = new Vector.<String>();
		private var _typeFactory:Dictionary = new Dictionary();	// Map of class to function that returns a new instance of that class.
		private var _stack:Vector.<SerializationStackEntry>;
		private var _stackDepth:int;
		
		private static const isPrimitiveMetadata:Metadata = Metadata.newInstance("isPrimitive",[new MetadataArgument("is","true")] );
		private static const notPrimitiveMetadata:Metadata = Metadata.newInstance("isPrimitive",[new MetadataArgument("is","false")] );
		
		private static const vectorElementTypeRegExp:RegExp = new RegExp("^Vector.<([a-zA-Z0-9:\.<>_]+)>$");
		private static const vectorElementTypeString:String = "Vector.<"
		
		public static var singletonTypes:Array = [Type];
		
		public function get stack():Vector.<SerializationStackEntry> {
			return _stack;
		}
		
		public function get stackDepth():int {
			return _stackDepth;
		}
		
		public function get current():SerializationStackEntry {
			var entry:SerializationStackEntry;
			if (_stack && _stackDepth > 0) {
				entry = _stack[_stackDepth-1];
			}
			return entry;
		}
		
		public var filter:Function;
		public var forceObject:Boolean;
		public var strict:Boolean;
		public var writeReadOnlys:Boolean;
		public var convertStringToNumber:Function; // Function takes String returns Number or NaN if you want it to skip assignment
		public var stringFilter:Function;
		public var cacheByObject:Boolean = false;
		public var checkVariants:Boolean = true;
		public var arrayMergeBehavior:String = Serialization.ARRAY_MERGE;
		
		public function Serialization( forceObject:Boolean = false, strict:Boolean = true, maintainStack:Boolean = false ) {
			this.forceObject = forceObject;
			this.strict = strict;
			if (maintainStack) {
				_stack = new Vector.<SerializationStackEntry>();
			} else {
				_stack = null;
			}
			_stackDepth = 0;
		}
		
		public function disposeStack():void {
			if (_stack) {
				for (var i:int=0; i<_stack.length; i++) {
					_stack[i].dispose();
				}
			}
		}
		
		private function getStackEntry( from:Object, to:Object ):SerializationStackEntry {
			var stackEntry:SerializationStackEntry;
			if (_stack) {
				if (_stack.length == _stackDepth) {
					_stack.push( stackEntry = new SerializationStackEntry( from, to, null ) );
				} else {
					stackEntry = _stack[_stackDepth];
					stackEntry.fromObject = from;
					stackEntry.toObject = to;
				}
				_stackDepth++
			}
			return stackEntry;
		}
		
		static public var _objectFieldLookup:TTLCache = new TTLCache( 5*60 );
		
		public function copyFields( from:Object, to:Object, type:Type = null, elementType:Type = null, field:Field = null, parent:Object = null): void {
			if (from == null || to == null) {
				return;
			}
			var stackEntry:SerializationStackEntry = getStackEntry(from,to);
			if (type == null) {
				if (forceObject) {
					type = OBJECT_TYPE;
				} else {
					type = Type.forInstance(to);
				}
			}
			var value:*;
			var valueNum:Number;
			if (type.isDynamic) {
				var key:*;
				var len:int, i:int;
				// Copy dynamic object fields (Array, Dictionary, Vector, or Object)
				
				if ( ( type.clazz == Array ) || (type.name.indexOf(vectorElementTypeString) >= 0) ) {
					if (elementType == null) {
						elementType = Serialization.getVectorElementType(type);
					}
					len = from.length;
					if (elementType) {
						// Copy elements of a known type
						if (Serialization.isPrimitive(elementType)) {
							// Copy primitive elements simply
							for (i=0; i<len; ++i) {
								if (stackEntry) {
									stackEntry.fieldKey = i;
								}
								value = from[i];
								if (value is String && stringFilter != null) {
									if (elementType.clazz == Boolean) {
										valueNum = convertStringToNumber(value);
										value = (valueNum==valueNum && valueNum!=0);
									} else {
										value = stringFilter(value);
									}
								} else if (filter != null && elementType.clazz != String) {
									value = filter(value);
								}
								to[i] = value;
							}
							if (arrayMergeBehavior == ARRAY_REPLACE) {
								to.length = len;
							}
						} else {
							// array or vector.
							// Copy complex elements
							var j:int = 0;
							for (i=0; i<len; ++i) {
								if (stackEntry) {
									stackEntry.fieldKey = i;
								}
								try {
									value = fromObject( from[i], elementType, field, from );
									if ( ( value == null ) || ( value is elementType.clazz ) ) {
										to[j++] = value;
									}
								}
								catch ( e:Error ) {
									trace("swallowing serialization error from index "+key + " Error: " + e.message);
								}
							}
							if (arrayMergeBehavior == ARRAY_REPLACE) {
								to.length = j;
							}
						}
					}
					else {
						// Copy elements of an unknown type, such as Object, Dictionary, or Array without the [ElementType] annotation
						j = 0;
						for (i=0; i<len; ++i) {
							value = from[i];
							if (stackEntry) {
								stackEntry.fieldKey = i;
							}
							if (value == null || Serialization.isPrimitiveValue(value)) {
								if (value is String && stringFilter != null) {
									value = stringFilter(value);
								} else if (filter != null) {
									value = filter(value);
								}
								if (convertStringToNumber != null && value is String && value.indexOf("!(") == 0) {
									value = convertStringToNumber(value.substring(1));
								}
								to[j++] = value;
							} else {
								try {
									elementType = getObjectType( value, null, field, parent );
									if (elementType == null) {
										elementType = Type.forInstance( value );
									}
								} catch(e:Error) {
									trace("ERROR: Could not get type. " + e.message);
									continue;	// Don't add elements that we can't get a type for, but keep adding the rest
								}
								if ( arrayMergeBehavior == ARRAY_REPLACE || to.length == j-1 || to[j] == null ) {
									to[j++] = fromObject( value, elementType, null, from );
								} else {
									copyFields( value, to[j++], elementType, null, null, from );
								}
							}
						}
						if (arrayMergeBehavior == ARRAY_REPLACE) {
							to.length = j;
						}
					}
				}
				else {
					if (elementType) {
						// Copy elements of a known type
						if (Serialization.isPrimitive(elementType)) {
							// Copy primitive elements simply
							for (key in from) {
								if (stackEntry) {
									stackEntry.fieldKey = key;
								}
								value = from[key];
								if (value is String && stringFilter != null) {
									if (elementType.clazz == Boolean) {
										valueNum = convertStringToNumber(value);
										value = (valueNum==valueNum && valueNum!=0);
									} else {
										value = stringFilter(value);
									}
								} else if (filter != null && elementType.clazz != String) {
									value = filter(value);
								}
								to[key] = value;
							}
						} else {
							// Copy complex elements
							for (key in from) {
								if (stackEntry) {
									stackEntry.fieldKey = key;
								}
								try {
									if (to[key] == null) {
										value = fromObject( from[key], elementType, field, from );
										if ( ( value == null ) || ( value is elementType.clazz ) ) {
											to[key] = value;
										}
									} else {
										copyFields( value, to[key], elementType, null, null, from );
									}
								}
								catch ( e:Error ) {
									trace("swallowing serialization error from index "+key + " Error: " + e.message);
								}
							}
						}
					}
					else {
						// Copy elements of an unknown type, such as Object, Dictionary, or Array without the [ElementType] annotation
						for (key in from) {
							value = from[key];
							if (stackEntry) {
								stackEntry.fieldKey = key;
							}
							if (value == null || Serialization.isPrimitiveValue(value)) {
								if (value is String && stringFilter != null) {
									value = stringFilter(value);
								} else if (filter != null) {
									value = filter(value);
								}
								if (convertStringToNumber != null && value is String && value.indexOf("!(") == 0) {
									value = convertStringToNumber(value.substring(1));
								}
								to[key] = value;
							} else {
								try {
									elementType = getObjectType( value, null, field, parent );
									if (elementType == null) {
										elementType = Type.forInstance( value );
									}
								} catch(e:Error) {
									trace("ERROR: Could not get type. " + e.message);
									continue;	// Don't add elements that we can't get a type for, but keep adding the rest
								}
								if (to[key] == null) {
									to[key] = fromObject( value, elementType, null, from );
								} else {
									copyFields( value, to[key], elementType, null, null, from );
								}
							}
						}
					}
				}
			} else {
				// Copy typed object fields
				var fieldMap:Dictionary = getObjectFieldMap( from );
				var elementMap:Dictionary = getTypeElementMap( type );
				var fieldName:String;
				var hasDynamicFields:Boolean = false;
				for (fieldName in from) {
					hasDynamicFields = true;
					copyTypedField( from, to, fieldName, elementType, stackEntry, fieldMap, elementMap );
				}
				// If there were no dynamic fields, then iterate through the typed fields.  (This won't work for typed classes declared as dynamic.)
				if (!hasDynamicFields) {
					var fromType:Type = Type.forInstance(from);
					if (fromType.clazz != Object) {
						for each( var fromField:Field in fromType.fields ) {
							if (fromField.isStatic == false && !fromField.getMetadata("Transient") && !fromField.type.getMetadata("Transient") && !fromField.getMetadata("Inject")) {
								copyTypedField( from, to, fromField.name, elementType, stackEntry, fieldMap, elementMap );
							}
						}
					}
				}
			}
			if (stackEntry) {
				--_stackDepth;
			}
		}
		
		private function copyTypedField(from:Object, to:Object, fieldName:String, elementType:Type, stackEntry:SerializationStackEntry, fieldMap:Dictionary, elementMap:Dictionary):void {
			var elementName:String;
			if (fieldMap == EMPTY_DICTIONARY || fieldMap[fieldName] === undefined) {
				elementName = fieldName;
			} else {
				elementName = fieldMap[fieldName];
				if (elementName == null) {
					return;
				}
			}
			var elementField:Field = elementMap[elementName];
			if (!elementField) {
				return;
			}
			var accessor:Accessor = elementField as Accessor;
			var value:*;
			var valueNum:Number;
			if (accessor == null || accessor.writeable) {
				if (stackEntry) {
					stackEntry.fieldKey = elementName;
				}
				var elementFieldType:Type = elementField.type;
				value = from[fieldName];
				if (isPrimitive(elementFieldType)) {
					if (elementFieldType.clazz == Number ) {
						if (value == "NaN") {
							to[elementName] = NaN;
						} else if (value != null) {
							if (value is Number || value is int || !isNaN(Number(value)) ) {
								to[elementName] = value;
							} else {
								if (value is String && null != convertStringToNumber) {
									valueNum = convertStringToNumber(value);
									if (valueNum==valueNum) {
										to[elementName] = valueNum;
									}
								}
							}
						}
					} else if (elementFieldType.clazz == int || elementFieldType.clazz == uint ) {
						if (value is Number || value is int || value is uint || !isNaN(Number(value)) ) {
							to[elementName] = value;
						} else {
							if (value is String && null != convertStringToNumber) {
								valueNum = convertStringToNumber(value);
								if (valueNum==valueNum) {
									to[elementName] = valueNum;
								}
							}
						}
					} else if (elementFieldType.clazz == String && value is Array) {
						to[elementName] = value[ int(Math.random() * value.length) ];
					} else if ( value is String && stringFilter != null) {
						if (elementFieldType.clazz == Boolean) {
							valueNum = convertStringToNumber(value);
							to[elementName] = (valueNum==valueNum && valueNum!=0);
						} else {
							to[elementName] = stringFilter(value);
						}
					} else if (filter != null && elementFieldType.clazz != String) {
						to[elementName] = filter(value);
					} else {
						to[elementName] = value;
					}
				} else if ( value == null || (elementFieldType.clazz == Object && objectIsEmpty(value) ) || ( singletonTypes.indexOf(elementFieldType.clazz) != -1 ) ) {
					// Alternately - if elementField is Object and value is primitive.
					to[elementName] = value;
				} else {
					if ((accessor && !accessor.readable) || to[elementName] == null || elementFieldType.clazz == Date || elementFieldType.clazz == Array || elementFieldType.clazz == Dictionary || elementFieldType.name.indexOf(vectorElementTypeString) >= 0 ) {
						to[elementName] = fromObject( value, elementFieldType, elementField, from );
					} else {
						if (value is elementFieldType.clazz) {
							copyFields( value, to[elementName], elementFieldType, elementType, elementField, from );
						} else {
							if (!elementFieldType.interfaces || elementFieldType.interfaces.indexOf("util::JsonCreator") == -1) {
								if (!isPrimitiveValue(value)) {
									copyFields( value, to[elementName], elementFieldType, elementType, elementField, from );
								} else {
									trace(value);
								}
							} else {
								var factoryFunction:Function = _typeFactory[elementFieldType.clazz];
								if (factoryFunction != null) {
									to[elementName] = factoryFunction(value);
								} else {
									to[elementName] = new elementFieldType.clazz(value);
								}
							}
						}
					}
				}
			}
		}
		
		private static var percentCache:TTLCache = new TTLCache( 5*60 );
		/**
		 * Pass a String ending in a percent sign, like "100%".
		 * Returns NaN if not a String, or the percent value as a number (divided by 100)
		 */
		public static function getAsPercent(data:Object):Number {
			var value:Number;
			if (data is String) {
				var dataStr:String = data as String;
				if ( !percentCache.hasItem( dataStr )  ) {
					var len:int = dataStr.length;
					if( dataStr.indexOf("%") == (len-1)) {
						value = Number(dataStr.substr(0,len-1)) / 100.0;
					}
					percentCache.putItem( dataStr, value );
				}
				else {
					value = percentCache.getItem(dataStr) as Number;
				}
			}
			return value;
		}
		
		public static function isPercent(data:Object):Boolean {
			if (data is String) {
				var dataStr:String = data as String;
				var len:int = dataStr.length;
				return dataStr.charAt(len-1) == "%";
			}
			return false;
		}
		
		static private var _variantNameLookup:TTLCache = new TTLCache( 5*60 );
		static private function getVariantRootName(name:String):String {
			var dotIndex:int = name.indexOf(".");
			if (dotIndex > 0) {
				var root:String = _variantNameLookup.getItem(name) as String;
				if ( !root ) {
					root = name.substr(0,dotIndex); 
					_variantNameLookup.putItem(name,root);
				}
				return root;
			}
			return name;
		}
		
		public static function clearAllCaches():void {
			_variantNameLookup.clear();
			_objectFieldLookup.clear();
			_typeFullNames.clear();
			_pkgLookup.clear();
			_typeCache.clear();
			_unknownTypeCache.clear();
			_typeElementMap.clear();
		}
		
		private static var _typeElementMap:TTLCache = new TTLCache(5*60);
		
		private static function getTypeElementMap( type:Type ):Dictionary {
			var result:Dictionary = _typeElementMap.getItem(type) as Dictionary;
			if (!result) {
				result = new Dictionary();
				for each (var field:Field in type.fields) {
					result[field.name] = field;
				}
				_typeElementMap.putItem( type, result );
			}
			return result;
		}
		
		private static var HELPER_INDEXES:Vector.<int> = new Vector.<int>(100,true);
		private static var HELPER_KEYS:Vector.<String> = new Vector.<String>(100,true);
		private static var EMPTY_DICTIONARY:Dictionary = new Dictionary();
		private static var HELPER_STRINGS:Vector.<String> = new Vector.<String>(100,true);
		private function getObjectFieldMap( obj:Object ):Dictionary {
			var variantCount:int = _activeVariants.length;
			if (variantCount == 0) {
				return EMPTY_DICTIONARY;
			}
			var key:String;
			var fieldLookup:Dictionary = _objectFieldLookup.getItem(obj) as Dictionary;
			if ( !fieldLookup ) {
				var numVariantFields:int = 0;
				for (key in obj) {
					var dotIndex:int = key.indexOf(".");
					if (dotIndex>0) {
						HELPER_INDEXES[numVariantFields] = dotIndex;
						HELPER_KEYS[numVariantFields++] = key;
					}
				}
				if (numVariantFields == 0) {
					fieldLookup = EMPTY_DICTIONARY;
				} else {
					// Begin cache fields by hash of keys
					var fields:Vector.<String> = getFieldsObjNoAlloc(obj,HELPER_STRINGS,false);
					var keyHash:uint = 0;
					for (var j:int=0; (key=fields[j])!=""; j++) {
						keyHash += CRC32.checkSum(key,0,0);	// sum so that order is irrelevant
					}
					fieldLookup = _objectFieldLookup.getItem(keyHash) as Dictionary;
					// End cache fields by hash of keys
					if (!fieldLookup) {
						fieldLookup = new Dictionary();
						for ( var i:int=0; i<variantCount; ++i) {
							var variant:String = _activeVariants[i];
							for (j=0; j<numVariantFields; j++) {
								key = HELPER_KEYS[j];
								dotIndex = HELPER_INDEXES[j];
								if (key.indexOf(variant) == dotIndex && key.length == (variant.length + dotIndex)) {
									var root:String = getVariantRootName(key);
									if (fieldLookup[root] === undefined) {
										fieldLookup[root] = null;
										fieldLookup[key] = root;
									}
								}
							}
						}
						_objectFieldLookup.putItem(keyHash, fieldLookup);
					}
				}
				_objectFieldLookup.putItem(obj, fieldLookup);
			}
			return fieldLookup;
		}
		
		static private var _vectorElementTypeLookup:Dictionary = new Dictionary();
		
		static private function getVectorElementType(vectorType:Type):Type {
			var elementType:Type = _vectorElementTypeLookup[vectorType];
			if ( !elementType ) {
				var elementTypeName:Array = vectorType.name.match( vectorElementTypeRegExp );
				if (elementTypeName && elementTypeName.length) {
					elementType = Type.forName(elementTypeName[1]);
					_vectorElementTypeLookup[vectorType] = elementType;
				}
			}
			return elementType;
		}
		
		[Inline]
		static public function objectIsEmpty(object:Object):Boolean {
			var result:Boolean = true;
			for ( var key:* in object ) {
				result = false;
				break;
			}
			return result;
		}
		
		static public function getSortedKeys(object:Object):Array {
			var keys:Array = [];
			for (var key:* in object) {
				keys.push(key);
			}
			if (keys.length > 0) {
				if (keys[0] is int || keys[0] is Number) {
					keys.sort(Array.NUMERIC);
				} else {
					keys.sort();
				}
			}
			return keys;
		}
		
		static public function getSortedFields(type:Type):Array {
			var keys:Array = [];
			for each (var field:Field in type.fields) {
				keys.push(field);
			}
			if (keys.length > 0) {
				keys.sortOn("name");
			}
			return keys;
		}
		
		static public function getSortedFieldsObj(obj:Object):Array {
			var keys:Array = [];
			for (var field:String in obj) {
				keys.push(field);
			}
			if (keys.length > 0) {
				keys.sort();
			}
			return keys;
		}
		
		static private function getFieldsObjNoAlloc(obj:Object,fields:Vector.<String>,sort:Boolean=true):Vector.<String> {
			var i:int=0;
			var max:int=fields.length;
			var maxMinusOne:int=max-1;
			for (var field:String in obj) {
				if (i>=maxMinusOne) {
					throw new Error("Number of fields exceeded capacity.");
				}
				fields[i++] = field;
			}
			while (i<max && fields[i] != "") {
				fields[i++] = "";
			}
			if (sort) {
				fields.sort(2);
			}
			return fields;
		}
		
		static private const OBJECT_TYPE:Type = Type.forClass(Object);
		static private const ARRAY_TYPE:Type = Type.forClass(Array);
		
		static private var _typeFullNames:TTLCache = new TTLCache( 5*60 );
		
		public function fromObject( from:Object, type:Type = null, field:Field = null, parent:Object = null, createOnly:Boolean = false ): * {
			if (from == null) {
				return null;
			}
			
			var haveType:Boolean = false;
			if ( type != null && from.hasOwnProperty(TYPE_FIELD) ) {
				var typeFullName:String = _typeFullNames.getItem(type.fullName) as String;
				if ( !typeFullName ) {
					typeFullName = type.fullName.replace( "::", "." );
					_typeFullNames.putItem( type.fullName, typeFullName );
				}
				haveType = ( typeFullName == from[TYPE_FIELD] );
			}
			if (!haveType && (type == null || type.isInterface || (type.isDynamic == false && Serialization.isPrimitive(type) == false))) {
				type = getObjectType( from, type, field, parent );
			}
			if (type == null || isPrimitive(type)) {
				return from;
			} else {
				var clazz:Class = type.clazz;
				var to:Object;
				if (clazz == Date) {
					to = new Date(from);
				} else if(clazz == Class) {
					// "from" can be a Class or class name (String). Handle both cases.
					if ( from is Class ) {
						to = from;
					}
					else {
						var typeName:String;
						var dot:int = from.lastIndexOf(".");
						if (dot >= 0) {
							typeName = from.substr(dot+1);
						}
						var pkgPrefix:String = getElementTypePkg(field);
						to = decodeType(pkgPrefix + typeName).clazz;
					}
				} else if ( clazz == ByteArray ) {
					var fromBa:ByteArray = from as ByteArray;
					var toBa:ByteArray = new ByteArray();
					copyFields(from, toBa, type );
					fromBa.position = 0;
					toBa.position = 0;
					fromBa.readBytes( toBa );
					fromBa.position = 0;
					toBa.position = 0;
					to = toBa;
				} else {
					var factoryFunction:Function = _typeFactory[clazz];
					if (type.interfaces && type.interfaces.indexOf("util::JsonCreator") != -1) {
						var jsonWriter:JsonWriter = from as JsonWriter;
						if (jsonWriter) {
							from = jsonWriter.jsonValue;
						}
						if (factoryFunction != null) {
							to = factoryFunction(from);
						} else {
							to = new clazz(from);
						}
					} else {
						if (factoryFunction != null) {
							to = factoryFunction();
						} else {
							to = new clazz();
						}
						if (!createOnly) {
							var pkg:String = null;
							var elementType:Type = null;
							if (type.isDynamic && field && field.type == type) {
								elementType = getElementType(field);
								if (elementType == null) {
									elementType = getVectorElementType(type);
								}
								pkg = getElementTypePkg(field);
								if (pkg) {
									_defaultPackages.unshift(pkg);
								}
							}
							try {
								copyFields( from, to, type, elementType, field );
							}
							catch ( e:Error ) {
								if ( strict ) {
									throw e;
								}
								else {
									trace("swallowing serialization error. to: "+to+" from: "+from+" Error: "+e.message);
								}
							}
							if (pkg) {
								_defaultPackages.shift();
							}
						}
					}
				}
				return to;
			}
		}
		
		// Must have a period as the first character
		public function setVariant( variantName:String ):void {
			if (_activeVariants.indexOf(variantName)==-1) {
				_activeVariants.push( variantName );
			}
		}
		
		public function setVariants( variantNames:Array ):void {
			for each (var variantName:String in variantNames) {
				if (_activeVariants.indexOf(variantName)==-1) {
					_activeVariants.push( variantName );
				}
			}
		}
		
		public function clearVariant( variantName:String ):void {
			var i:int = _activeVariants.indexOf(variantName);
			if (i>=0) {
				_activeVariants.splice(i,1);
			}
		}
		
		public function clearVariants( variantNames:Array ):void {
			for each (var variantName:String in variantNames) {
				var i:int = _activeVariants.indexOf(variantName);
				if (i>=0) {
					_activeVariants.splice(i,1);
				}
			}
		}
		
		public function clearAllVariants():void {
			_activeVariants.length = 0;
		}
		
		public function addDefaultPackage(packageName:String):void {
			_defaultPackages.push( packageName + "." );
		}
		
		public function clearDefaultPackages():void {
			_defaultPackages.length = 0;
		}
		
		public function addClassFactory( clazz:Class, func:Function ):void {
			_typeFactory[clazz] = func;
		}
		
		public function removeClassFactory( clazz:Class ):void {
			delete _typeFactory[clazz];
		}
		
		public function createClassFromFactory( clazz:Class ): * {
			var result:* = null;
			if ( _typeFactory[clazz] != undefined ) {
				var func:Function = _typeFactory[clazz];
				result = func();
			}
			return result;
		}
		
		static private function getElementTypePkg(field:Field,defaultPkg:String=null):String {
			var pkg:String = getMetadataValue( field, "ElementType", "pkg" );
			if (pkg) {
				pkg += ".";
			}
			return pkg ? pkg : defaultPkg;
		}
		
		private static var _pkgLookup:TTLCache = new TTLCache( 5*60 );
		private static var _typeNameLookup:TTLCache = new TTLCache( 5* 60 );
		
		private function getObjectType( object:Object, type:Type, field:Field, parent:Object = null): Type {
			if (forceObject) {
				if (object is Array) {
					return ARRAY_TYPE;
				} else {
					return OBJECT_TYPE;
				}
			}
			var typeFieldName:String = TYPE_FIELD;
			var pkg:String = "";
			var dot:int;
			var metadata:Metadata;
			if (field && field.metadata && field.metadata.length > 0) {
				var metadatas:Array = field.getMetadata("ElementType");
				if (metadatas && metadatas.length > 0) {
					metadata = metadatas[0];
					var arg:MetadataArgument = metadata.getArgument("typeField");
					if (arg) {
						typeFieldName = arg.value;
					}
					arg = metadata.getArgument("pkg");
					if (arg) {
						pkg = _pkgLookup.getItem(arg.value) as String;
						if ( !pkg ) {
							pkg = arg.value + ".";
							_pkgLookup.putItem(arg.value, pkg);
						}
					}
				}
				metadatas = field.getMetadata("TypeProvider");
				if (metadatas && metadatas.length > 0) {
					metadata = metadatas[0];
					var typeProvider:String = (metadata.arguments[0] as MetadataArgument).value;
					dot = typeProvider.lastIndexOf(".");
					var typeProviderClassName:String = typeProvider.substr(0,dot);
					var typeProviderFunctionName:String = typeProvider.substr(dot+1);
					var typeProviderClass:Class = getDefinitionByName(typeProviderClassName) as Class;
					var typeProviderFunction:Function = typeProviderClass[typeProviderFunctionName];
					var typeClass:Class = typeProviderFunction(parent,field.name);
					return Type.forClass( typeClass );
				}
			}
			if (object.hasOwnProperty(typeFieldName)) {
				var typeName:String = object[typeFieldName];
				var specifiedType:Type = decodeType(typeName);
				if (specifiedType != null) {
					type = specifiedType;
				}
				var origTypeName:String = typeName;
				if ( _typeNameLookup.hasItem(origTypeName) ) {
					typeName = String( _typeNameLookup.getItem(origTypeName) );
				}
				else {
					dot = typeName.lastIndexOf(".");
					if (dot >= 0) {
						// DEFINITELY CACHE HERE
						typeName = typeName.substr(dot+1);
						dot = typeName.lastIndexOf("$");
						if (dot >= 0) {
							typeName = typeName.substr(dot+1);
						}
					}
					_typeNameLookup.putItem(origTypeName, typeName);
				}
				
				var baseName:String = typeName;
				
				if (pkg != "") {
					typeName = pkg + baseName;
					type = decodeType(typeName);
				}
				
				if ( type == null ) {
					for each (var defaultPackage:String in _defaultPackages) {
						specifiedType = decodeType(defaultPackage + baseName);
						if (specifiedType != null) {
							type = specifiedType;
							break;
						}
					}
				}
				
				if (type == null || type.isInterface) {
					var errMsg:String = 'Could not find class "' + typeName + '" on client for "' + origTypeName + '"';
					if ( strict ) {
						throw new Error(errMsg);
					} else {
						trace(errMsg);
					}
				}
			}
			else if ( !isPrimitiveValue(object) ) {
				var objectType:Type = Type.forInstance( object );
				if ( (type != null && type.clazz == Object) || (objectType.clazz != Object && objectType.clazz != Array && objectType.clazz != Dictionary) ) {
					type = objectType;
				}
			}
			return type;
		}
		
		
		protected static var _typeCache:TTLCache = new TTLCache( 5*60 );
		protected static var _unknownTypeCache:TTLCache = new TTLCache( 5*60 );
		
		protected static var _unknownSentinel:Object = {unknown:true};
		
		protected static function decodeType(typeName:String):Type {
			var type:Type = _typeCache.getItem( typeName ) as Type;
			if ( !type ) {
				var val:Object = _unknownTypeCache.getItem( typeName );
				if ( !val ) {
					if (typeName.indexOf(".") > 0) {
						try {
							getDefinitionByName(typeName);	// Do this here to avoid that error message logged by Type.forName if it fails.
							type = Type.forName( typeName );
							_typeCache.putItem(typeName, type);
						} catch(e:ReferenceError) {
							type = null;
							_unknownTypeCache.putItem(typeName, _unknownSentinel);
						}
					}
				}
			}
			return type;
		}
		
		static private function getElementType( field:Field ):Type {
			var type:Type;
			var typeName:String = getMetadataValue( field, "ElementType" );
			if (typeName != null) {
				type = Type.forName(typeName);
			}
			return type;
		}
		
		static public function getMetadataValue( hasMetadata:IMetadataContainer, annotation:String, arg:*=0 ):String {
			var value:String;
			if (hasMetadata != null) {
				var metadatas:Array = hasMetadata.getMetadata(annotation);
				if (metadatas && metadatas.length > 0) {
					var metadata:Metadata = metadatas[0];
					var argument:MetadataArgument;
					if (arg is String) {
						argument = metadata.getArgument(String(arg));
					} else if (arg is int && arg < metadata.arguments.length && !metadata.arguments[arg].key) {
						argument = MetadataArgument(metadata.arguments[arg]);
					}
					if (argument != null) {
						value = argument.value;
					}
				}
			}
			return value;
		}
		
		public function toObject( from:Object, to:Object = null ): Object {
			if (from == null) {
				return null;
			}
			var date:Date;
			var type:Type = Type.forInstance(from);
			var stackEntry:SerializationStackEntry = getStackEntry(from,to);
			var fieldName:String;
			if (type.isDynamic) {
				var value:*;
				var fieldType:Type;
				if (type.clazz == Dictionary || type.clazz == Object) {
					//
					// Dynamic object
					//
					if (to == null) {
						to = new Object();
					}
					for (var key:* in from) {
						fieldName = String(key);
						if (stackEntry) {
							stackEntry.fieldKey = fieldName;
						}
						value = from[key];
						fieldType = Type.forInstance(value);
						if (isPrimitive(fieldType)) {
							if (filter != null) {
								value = filter(value);
							}
							to[fieldName] = value;
						} else {
							if (fieldType.clazz == Date) {
								date = from[fieldName] as Date;
								to[fieldName] = date != null ? date.time : null;
							} else {
								to[fieldName] = new Object();
								to[TYPE_FIELD] = fieldType.name;
								toObject( from[fieldName], to[fieldName] );
							}
						}
					}
				} else {
					//
					// Array or vector
					//
					var len:int = from.length;
					if (!(to is Array)) {
						to = new Array();
					}
					for (var i:int=0; i<len; ++i) {
						if (stackEntry) {
							stackEntry.fieldKey = i;
						}
						value = from[i];
						fieldType = (value != null) ? Type.forInstance(value) : null;
						if (value == null || isPrimitive(fieldType)) {
							if (filter != null) {
								value = filter(value);
							}
							to[i] = value;
						} else {
							if (fieldType.clazz == Date) {
								to[i] = (from[i] as Date).time;
							} else {
								to[i] = toObject( from[i] );
							}
						}
					}
				}
			} else {
				//
				// Typed object
				//
				if (to == null) {
					to = new Object();
				}
				//				to[TYPE_FIELD] = type.fullName.replace("::",".");
				//				to[TYPE_FIELD] = "."+type.name;
				for each (var field:Field in type.fields) {
					if (field.isStatic == false && !field.getMetadata("Transient") && !field.type.getMetadata("Transient") && !field.getMetadata("Inject")) {
						fieldName = field.name;
						if (stackEntry) {
							stackEntry.fieldKey = fieldName;
						}
						fieldType = field.type;
						value = from[fieldName];
						if (isPrimitive(fieldType)) {
							if (filter != null) {
								value = filter(value);
							}
							to[fieldName] = value;
						} else {
							if (fieldType.clazz == Date) {
								date = value as Date;
								to[fieldName] = date != null ? date.time : null;
							} else if (fieldType.clazz == Function) {
								to[fieldName] = String(value);
							} else if (fieldType.clazz == Class) {
								to[fieldName] = Type.forClass(value).fullName.replace("::",".");
							} else {
								to[fieldName] = toObject( value );
							}
						}
					}
				}
			}
			if (stackEntry) {
				--_stackDepth;
			}
			return to;
		}
		
		public var JSON_INDENT:String = "  ";
		
		private function primitiveFieldAsJson(field:Field, value:*): String {
			var type:Type = field.type;
			var serializeAs:String = getMetadataValue(field, "SerializeAs");
			if (serializeAs != null) {
				type = Type.forName(serializeAs);
				if (serializeAs == "String") {
					if (serializeAs.length > 1) {
						var radix:int = int(getMetadataValue(field, "SerializeAs", 1));
						value = value.toString(radix);
						if (radix == 16) {
							value = "0x" + ("00000000"+value).substr(-8);
						}
					} else {
						value = String(value);
					}
				}
			}
			var snippet:String = '"' + field.name + '": ' + primitiveAsJson(type,value);
			return snippet;
		}
		
		private function primitiveAsJson(type:Type,value:*): String {
			var result:String;
			switch (type.name) {
				case "Boolean":
					if (value) {
						result = "true";
					} else {
						result = "false";
					}
					break;
				case "String":
					result = '"' + value + '"';
					break;
				default:
					result = String(value);
					break;
			}
			return result;
		}
		
		static public function getClass( obj:Object ):Class {
			var cls:Class = (obj as Class) || (obj.constructor as Class);
			if (cls == null) {
				cls = getDefinitionByName(getQualifiedClassName(obj)) as Class;
			}
			return cls;
		}
		
		private function findFrom(from:Object):SerializationStackEntry {
			var result:SerializationStackEntry = null;
			if (_stack) {
				try {
					var i:int = _stackDepth-1;
					while (i>=0) {
						var entry:SerializationStackEntry = _stack[i--];
						if (entry.fromObject == from) {
							result = entry;
							break;
						}
					}
				} catch( e:Error ) {
					if (e.errorID == 2090) {
						// Do nothing
					} else {
						trace( "Serialization::findFrom()" + e.message );
					}
				}
			}
			return result;
		}
		
		public function toJsonString( from:Object, excludeDefaults:Object = null, indent:int = 0, myType:Type = null, myField:Field = null, defaultPackage:String = null ): String {
			if (from == null) {
				return '"null"';
			}
			if (!_stack) {
				_stack = new Vector.<SerializationStackEntry>();
			}
			var value:*;
			var json:String = "";
			var child:String;
			var arrayJson:Vector.<String> = new Vector.<String>();
			var passedInType:Type = myType;
			if (myType == null || !(from is myType.clazz) || getClass(from) != myType.clazz) {
				myType = Type.forInstance(from);
			}
			var elementType:Type;
			var pkg:String = getElementTypePkg(myField,defaultPackage);
			var stackEntry:SerializationStackEntry = getStackEntry(from,null);
			var fieldName:String;
			if (myType.isDynamic) {
				var fieldType:Type;
				if (myType.clazz == Dictionary || myType.clazz == Object) {
					//
					// Dynamic object
					//
					elementType = getElementType(myField);
					var keys:Array = Serialization.getSortedKeys(from);
					for each (fieldName in keys) {
						value = from[fieldName];
						if (stackEntry) {
							stackEntry.fieldKey = fieldName;
						}
						if (value != null) {
							try {
								fieldType = Type.forInstance(value);
							} catch( e:Error ) {
								continue;
							}
							if (isPrimitive(fieldType)) {
								if (excludeDefaults != null && excludeDefaults.hasOwnProperty(fieldName) && (excludeDefaults[fieldName] == value || (isNaN(excludeDefaults[fieldName]) && isNaN(value)))) {
									continue;
								}
								if (!(value is Number) || !isNaN(value)) {
									arrayJson.push( '"' + fieldName + '": ' + primitiveAsJson(fieldType,value) );
								}
							} else {
								if (fieldType.clazz == Date) {
									arrayJson.push( '"' + fieldName + '": ' + value == null ? "null" : String((value as Date).time) );
								} else if (fieldType.clazz == Function) {
									arrayJson.push( '"' + fieldName + '": ' + String(value) );
								} else if (fieldType.clazz == Class) {
									arrayJson.push( '"' + fieldName + '": ' + Type.forClass(value).fullName.replace("::",".") );
								} else {
									if (findFrom(value)) {
										arrayJson.push( "null" );	// Cut circular references
									} else {
										child = toJsonString( from[fieldName], (excludeDefaults != null && excludeDefaults.hasOwnProperty(fieldName)) ? excludeDefaults[fieldName] : null, indent+1, elementType, null, pkg );
										arrayJson.push( '"' + fieldName + '": ' + child );
									}
								}
							}
						}
					}
					if (arrayJson.length > 0) {
						json += "{\n" + StringUtil.repeat(JSON_INDENT,indent+1);
						json += arrayJson.join( ",\n" + StringUtil.repeat(JSON_INDENT,indent+1) );
						json += "\n" + StringUtil.repeat(JSON_INDENT,indent) + "}";
					} else {
						json += "{}";
					}
				} else {
					//
					// Array or vector
					//
					elementType = getVectorElementType(myType);
					
					json += "[";
					if (from.hasOwnProperty("length")) {
						var len:int = from.length;
						var primitives:Boolean = true;
						for (var i:int=0; i<len; ++i) {
							if (stackEntry) {
								stackEntry.fieldKey = i;
							}
							value = from[i];
							try {
								fieldType = Type.forInstance(value);
							} catch( e:Error ) {
								continue;
							}
							if (isPrimitive(fieldType)) {
								arrayJson.push( String(value) );
							} else {
								if (fieldType.clazz == Date) {
									arrayJson.push( value == null ? "null" : String((value as Date).time) );
								} else if (fieldType.clazz == Function) {
									arrayJson.push( String(value) );
								} else if (fieldType.clazz == Class) {
									arrayJson.push( Type.forClass(value).fullName.replace("::",".") );
								} else {
									if (findFrom(value)) {
										arrayJson.push( "null" );	// Cut circular references
									} else {
										primitives = false;
										arrayJson.push( toJsonString(from[i], null, indent+1, elementType, null, pkg) );
									}
								}
							}
						}
						if (!primitives || arrayJson.length > 10) {
							json += "\n" + StringUtil.repeat(JSON_INDENT,indent+1);
							json += arrayJson.join(",\n"+StringUtil.repeat(JSON_INDENT,indent+1)) + "\n" + StringUtil.repeat(JSON_INDENT,indent);
						} else {
							json += arrayJson.join(",");
						}
					}
					json += "]";
				}
			} else {
				//
				// Typed object
				//
				var jsonWriter:JsonWriter = from as JsonWriter;
				if (jsonWriter != null) {
					json += JSON.stringify( jsonWriter.jsonValue );
				} else {
					var serializeAs:String = getMetadataValue(myType,"SerializeAs");
					if (serializeAs) {
						arrayJson.push( '"' + TYPE_FIELD + '": "' + serializeAs + '"' );
					} else if (passedInType != myType) {
						var typeName:String = myType.fullName.replace("::",".");
						if (pkg != null && typeName.indexOf(pkg) == 0) {
							typeName = typeName.substr( pkg.length );
						}
						arrayJson.push( '"' + TYPE_FIELD + '": "' + typeName + '"' );
					}
					var fields:Array = getSortedFields(myType);
					for each (var field:Field in fields) {
						if ( field.name == "mParent" ) continue;
						if ( field.getMetadata("JsonIgnore") ) continue;
						if (field.isStatic == false && !field.getMetadata("Transient") && !field.type.getMetadata("Transient") && !field.getMetadata("Inject")) {
							var accessor:Accessor = field as Accessor;
							if (accessor == null || (accessor.readable && (writeReadOnlys || accessor.writeable || field.getMetadata("Serialize")))) {
								fieldName = field.name;
								value = from[fieldName];
								if (findFrom(value)) {
									continue;
								}
								if (stackEntry) {
									stackEntry.fieldKey = fieldName;
								}
								if (value != null) {
									fieldType = field.type;
									if (isPrimitive(fieldType) || (fieldType.clazz == Object && isPrimitiveValue(value))) {
										if (excludeDefaults != null && excludeDefaults.hasOwnProperty(fieldName) && (excludeDefaults[fieldName] == value || (isNaN(excludeDefaults[fieldName]) && isNaN(value)))) {
											continue;
										}
										if (!(value is Number) || !isNaN(value)) {
											arrayJson.push( primitiveFieldAsJson(field,value) );
										}
									} else {
										if (fieldType.clazz == Date) {
											if (value != null) {
												arrayJson.push( '"' + fieldName + '": ' + String((value as Date).time) );
											}
										} else if (fieldType.clazz == Function) {
											arrayJson.push( '"' + fieldName + '": ' + String(value) );
										} else {
											child = toJsonString( value, (excludeDefaults != null && excludeDefaults.hasOwnProperty(fieldName)) ? excludeDefaults[fieldName] : null, indent+1, fieldType, field, pkg );
											arrayJson.push( '"' + fieldName + '": ' + child );
										}
									}
								}
							}
						}
					}
					if (arrayJson.length > 0) {
						json += "{\n" + StringUtil.repeat(JSON_INDENT,++indent);
						json += arrayJson.join( ",\n" + StringUtil.repeat(JSON_INDENT,indent--) );
						json += "\n" + StringUtil.repeat(JSON_INDENT,indent) + "}";
					} else {
						json += "{}";
					}
				}
			}
			if (stackEntry) {
				--_stackDepth;
			}
			return json;
		}
		
		[Inline]
		static public function isPrimitiveValue( value:Object ): Boolean {
			return value is Boolean || value is int || value is String || value is Number || value is uint;
		}
		
		static public function isPrimitive( type:Type ): Boolean {
			//			if (type.hasExactMetadata(isPrimitiveMetadata)) {
			//				return true;
			//			}
			//			if (type.hasExactMetadata(notPrimitiveMetadata)) {
			//				return false;
			//			}
			switch (type.name) {
				case "Boolean":
				case "int":
				case "Number":
				case "String":
				case "uint":
					//					type.addMetadata( isPrimitiveMetadata );
					return true;
				default:
					//					type.addMetadata( notPrimitiveMetadata );
					return false;
			}
		}
		
		//
		// disposeObject() - recursively sets all data members to null.
		//
		// Releases references that can defeat the garbage collector.
		//
		static public function disposeObject( obj:Object ): void {
			var disposeDebugElementName:String = null;
			try {
				if ( obj == null || obj is ByteArray ) {
					return;
				}
				else if ( obj is Array || obj is Vector.<*> || (obj.hasOwnProperty("length") && obj.hasOwnProperty("fixed")) ) {
					var len:int = obj.length;
					for ( var i:int = 0; i < len; i++ ) {
						if ( !isPrimitiveValue( obj[i] ) ) {
							disposeObject( obj[i] );
						}
						obj[i] = null;
					}
				}
				else if ( !isPrimitiveValue( obj ) ) {
					var type:Type = Type.forInstance( obj );
					if ( type.isDynamic ) {
						var deleteKey:Boolean = obj is Dictionary;
						for ( var prop:String in obj ) {
							disposeDebugElementName = prop;
							var val:* = obj[prop];
							if ( !isPrimitiveValue( val ) ) {
								disposeObject( val );
							}
							obj[prop] = null;
							if ( deleteKey ) {
								delete obj[prop];
							}
						}
					}
					else {
						for each (var elementField:Field in type.fields) {
							var elementName:String = elementField.name;
							disposeDebugElementName = elementName;
							var accessor:Accessor = elementField as Accessor;
							var constant:Boolean = elementField is Constant;
							var static:Boolean = elementField.isStatic;
							if ( !static && !constant && ( accessor == null || accessor.writeable) ) {
								val = obj[elementName];
								if ( !isPrimitiveValue( val ) ) {
									disposeObject( val );
								}
								obj[elementName] = null;
							}
						}
					}
				}
			} catch (e:Error) {
				var fieldNames:Array = [];
				try {
					if (type != null) {
						for each (elementField in type.fields) {
							elementName = elementField.name;
							accessor = elementField as Accessor;
							constant = elementField is Constant;
							static = elementField.isStatic;
							if ( !static && !constant && ( accessor == null || accessor.writeable) ) {
								fieldNames.push(elementName);
							}
						}
					}
				} catch (x:Error) {
					// skip
				}
				ErrorManager.reportClientError("Serialization::disposeObject error",e.message,e.getStackTrace(),null,{"field":disposeDebugElementName,"index":i,"field_names":fieldNames.join(", ")});
			}
		}
	}
}