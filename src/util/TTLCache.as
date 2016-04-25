package util
{
	import flash.events.TimerEvent;
	import flash.utils.Dictionary;
	import flash.utils.Timer;
	import flash.utils.getTimer;

	/**
	 * TTLCache - key/value cache that expires and deletes items after a specified interval.
	 * 
	 * Also maintains a static list of all TTLCache instances, so all can be cleared globally
	 * if necessary.
	 * 
	 */
	public class TTLCache
	{
		// Weak-key dictionary tracks active instances.
		private static var _instances:Dictionary = new Dictionary( true );
		
		private var _items:Dictionary = new Dictionary();
		private var _itemCount:int = 0;
		private var _ttl:int;
		private var _sweepInterval:int;
		private var _sweepTimer:Timer;

		/**
		 * Clear all instances of TTLCache.
		 */
		static public function clearAll(): void {
			for ( var cache:TTLCache in _instances ) {
				cache.clear();
			}
		}

		/**
		 * Constructor.
		 * 
		 * @param ttlSeconds - Item TTL (time-to-live) in seconds.
		 * 
		 */
		public function TTLCache( ttlSeconds:Number ) {
			_instances[this] = 1;
			_ttl = ttlSeconds * 1000;
			// Check expiration at one-tenth the TTL for items,
			// but no more often than every 10 seconds.
			_sweepInterval = Math.max( 10000, _ttl / 10 );
		}

		public function putItem( key:Object, value:Object ): void {
			var item:CacheItem = _items[key];
			if ( item ) {
				item.object = value;
				item.ts = getTimer();
			}
			else {
				_items[key] = new CacheItem( value );
				_itemCount++;
			}
			if ( !_sweepTimer || !_sweepTimer.running ) {
				startTimer();
			}
		}
		
		public function hasItem( key:Object ): Boolean {
			return _items[key] != undefined;
		}
		
		public function getItem( key:Object ): Object {
			var result:Object;
			var item:CacheItem = _items[key];
			if ( item ) {
				result = item.object;
				item.ts = getTimer();
			}
			return result;
		}
		
		public function removeItem( key:Object ): void {
			var item:CacheItem = _items[key];
			if ( item ) {
				delete _items[key];
				_itemCount--;
			}
			if ( _itemCount == 0 ) {
				stopTimer();
			}
		}
		
		public function clear(): void {
			_itemCount = 0;
			_items = new Dictionary();
			stopTimer();
		}
		
		private function startTimer(): void {
			if ( !_sweepTimer ) {
				_sweepTimer = new Timer( _sweepInterval );
				_sweepTimer.addEventListener( TimerEvent.TIMER, sweep );
			}
			_sweepTimer.start();
		}
		
		private function stopTimer(): void {
			if ( _sweepTimer ) {
				_sweepTimer.stop();
			}
		}
		
		private function sweep( event:TimerEvent ): void {
			var t:int = getTimer();
			
			var deleteKeys:Vector.<String>;
			
			for ( var key:* in _items ) {
				var item:CacheItem = _items[key];
				var dt:int = t - item.ts;
				if ( dt >= _ttl ) {
					if ( !deleteKeys ) {
						deleteKeys = new Vector.<String>();
					}
					deleteKeys.push( key );
				}
			}
			
			if ( deleteKeys ) {
				for each ( key in deleteKeys ) {
					delete _items[key];
					_itemCount--;
				}
				if ( _itemCount == 0 ) {
					stopTimer();
				}
			}
		}
	}
}

import flash.utils.getTimer;

internal class CacheItem {
	public var object:Object;
	public var ts:int;
	
	public function CacheItem( obj:Object ) {
		this.object = obj;
		this.ts = getTimer();
	}
}