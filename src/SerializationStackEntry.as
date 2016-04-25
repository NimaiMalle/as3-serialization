package util
{
	public class SerializationStackEntry
	{
		public function SerializationStackEntry( fromObject:Object, toObject:Object, fieldKey:* ) {
			this.fromObject = fromObject;
			this.toObject = toObject;
			this.fieldKey = fieldKey;
		}
		
		public function dispose():void {
			fromObject = null;
			toObject = null;
			fieldKey = undefined;
		}

		public var fromObject:Object;
		public var toObject:Object;
		public var fieldKey:*;
	}
}