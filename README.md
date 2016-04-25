# BCG Serialization

Functions for JSON-derived ActionScript Objects and instantiating typed ActionScript classes, and visa versa.

## Overview

It is best practice never to use ActionScript Object instances in a large code-base in a team environment.  It is also best practice for your game behaviors and appearances be data driven.

In order to avoid using un-typed dynamic property buckets (Object), and be data driven, we’ve grown a substantial library for serializing and deserializing strongly typed ActionScript class instances.

Our library makes heavy use of the AS3 Commons *[reflec*t](http://www.as3commons.org/as3-commons-reflect/) library.  Please consult their documentation and familiarize yourself with the Type, and Field classes in particular.

## JSON Data vs. JSON Object

As of FlashPlayer 11 and Air 3.0, JSON is supported natively.  See Adobe's documentation [here](http://help.adobe.com/en_US/FlashPlatform/reference/actionscript/3/JSON.html).

In this document, when we refer to **JSON data**, we mean the JSON formatted text string.  When JSON textual data is passed to the Flash JSON.parse method, it returns a generic ActionScript Object.  We'll refer to this as a **JSON Object**.

## Type Persistence

To represent strongly type ActionScript class instances in JSON, we store class type names in a special field: **_type**

### Example JSON representation

#### ActionScript Class

	package dataModel
	{
		public class ActionData
		{
			public var title:String;
			public var value:int;
		}
	}

#### JSON Data

	{
		"actions": [
			{
				"_type": "dataModel.ActionData",
				"title": "This is a test",
				"value": 49
			}
	}

## API

### fromObject

	static public function fromObject(
		from:Object, type:Type = null,
		forceObject:Boolean = false, field:Field = null ): *

This function can be used to create a strongly typed ActionScript instance from an untyped dynamic Object.  Conceptually, there are three types of values you could supply for the from parameter:

#### From a JSON Object

If the JSON Object contains a _type field, then an object of that type will be created, and the fields copied from the JSON onto the new instance.

#### From any ActionScript instance

If you pass a typed instance, or any other ActionScript object like a Vector, an Array, etc., fromObject will return a deep clone of the instance.

#### From a JSON Object - forceObject true

If you pass a JSON Object even with a _type field, and you set forceObject to true, then the JSON Object itself will be cloned, including _type fields.

### toObject

	static public function toObject( from:Object, to:Object = null ): Object

Takes a typed ActionScript instance and returns a JSON Object, including _type fields as needed.

### toJsonString

	static public function toJsonString( from:Object,
		indent:int = 0, myType:Type = null, myField:Field = null, defaultPackage:String = null ): String

Takes a typed ActionScript instance and returns a JSON Data text, including _type fields as needed.  You only need to supply the from parameter - the rest are for internal use.

There is a public static var JSON_INDENT that defaults to two spaces, but can be set to other values to change the output formatting.

### copyFields

	static public function copyFields( from:Object, to:Object,
		type:Type = null, forceObject:Boolean = false, elementType:Type = null, field:Field = null): void

### isPrimitive

	static public function isPrimitive( type:Type ): Boolean

Helper function to determine if a give Type is an ActionScript primitive.

### isPrimitiveValue

	static public function isPrimitiveValue( value:Object ): Boolean

Helper function to determine if a give value is an ActionScript primitive value.

### getSortedKeys

	static public function getSortedKeys(object:Object):Array

Helper function to get the keys from a Dictionary, Object, Array, or Vector and return them in sorted order.

### getSortedFields

	static public function getSortedFields(type:Type):Array

Helper function get get the Field definitions for a given Type in sorted order.

### getSortedFieldsObj

	static public function getSortedFieldsObj(obj:Object):Array

Helper function get get the Field definitions for a typed instance in sorted order.

## Special Annotations and Interfaces

### JsonCreator

If a Class is annotated with **[JsonCreator]** then it is assumed to have a constructor that accepts a JSON Data string and will know how to deserialize itself from that.

This is used in very special cases like the Interval Class which has the JSON text representation of "### - ###" where the numbers are time stamps in millisectonds.

### JsonWriter

If a Class implements the JsonWriter interface, it has a public function get jsonValue() that returns a valid JSON value for itself.

### ElementType

Field within classes can have the **[ElementType("class_name")]** annotation.  This is often used for Dictionary or Array fields which are otherwise untyped by the ActionScript language.  The ElementType annotation can also have a few parameters.

#### pkg

Some JSON Data doesn't supply a fully qualified type name in the _type field, or maybe the class package hierarchy differs between client and server.  Use the pkg attribute to specify where to look for type names for a given field.

		[ElementType(pkg="dataModel.action")]

#### typeField

If the JSON data is coming from some other source, and specified it's type using a field name other than "_type", then you can tell the serializer about it using this attribute.  For example:

		[ElementType(typeField="my_type")]

#### Transient

To exclude a field from serialization, add the **[Transient]** attribute to it.

## Class Packages

There are times when JSON Data contains only the base _type names, and there may be several packages that need to be searched.  For these cases, you can give the static Serialization class one or more packages to check.  For example:

		Serialization.addDefaultPackage("dataModel");
		Serialization.addDefaultPackage("dataModel.event");
		Serialization.addDefaultPackage("dataModel.quest.condition");

In cases like this, make sure that you always clean up after you're done using the Serializer.

		Serialization.clearDefaultPackages();

## Class Factories

There are time when you need to create an instance of a given type using a function other than it's constructor.  A class may not have a default constructor, for instance, or you may want to always do some additional initialization.  You can give the Serialization class factory methods to call instead of new to create instances of specific Classes.  For example:

	Serialization.addClassFactory( SomeClass, SomeFunction );

## Data Variants

It can be helpful to have a single data definition but be able to specify alternate values for just certain fields.  This can be done using a dot notation in the JSON Data.  For example:

	{
		"actions": [
			{
				"_type": "dataModel.ActionData",
				"title": "This is a test",
				"value": 49,
				"value.v1": 100,
				"value.v2": 75
			}
	}

When going from data like this to a typed object, the default (non-dotted) name is used unless you've told the static Serialization class to use a particular variant.  For example:

	Serialization.setVariant(".v1");

This will cause Serialization to use the value of 100.

You can have more than one variant active at a time, but that only makes sense for orthogonal variants - have .v1 and .v2 both set is not useful, for example.

There's also a clearVariants call.

