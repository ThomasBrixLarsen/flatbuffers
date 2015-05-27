module flatbuffers;

import std.bitmanip;
import std.typecons;
import std.traits : isScalarType, isSomeString;

enum fileIdentifierLength = 4;

class ArgumentException : Error
{
	this(string msg, string argument) pure nothrow @safe
	{
		super(msg);
	}
}

class ArgumentOutOfRangeException : Error
{
	this(string argument, long value, string msg) pure nothrow @safe
	{
		super(msg);
	}
}

class InvalidOperationException : Error
{
	this(string msg) pure nothrow @safe
	{
		super(msg);
	}
}

struct FlatBufferIterator(ParentType, ReturnType, alias accessor)
{
	ParentType parent;
	int index;
	
	this(ParentType parent)
	{
		this.parent = parent;
	}
	
	int length()
	{
		mixin("return parent."~accessor~"Length;");
	}
	
	bool empty()
	{
		return index == length;
	}
	
	ReturnType popFront()
	{
		mixin("return parent."~accessor~"(++index);");
	}
	
	ReturnType front()
	{
		mixin("return parent."~accessor~"(index);");
	}
	
	ReturnType opIndex(int index)
	{
		mixin("return parent."~accessor~"(index);");
	}
	
	static if(isScalarType!(ReturnType) || isSomeString!(ReturnType))
		alias ApplyType = ReturnType;
	else
		alias ApplyType = Nullable!ReturnType;
	
	int opApply(int delegate(ApplyType) operations)
	{
		ReturnType temp;
		int result = 0;
		for(int number=0; number<length(); ++number)
		{
			static if(isScalarType!(ReturnType) || isSomeString!(ReturnType))
				result = operations(opIndex(number));
			else
				mixin("result = operations(parent."~accessor~"(temp, number));");
			if(result)
				break;
		}
		return result;
	}
	
	int opApply(int delegate(int, ApplyType) operations)
	{
		ReturnType temp;
		int result = 0;
		for(int number=0; number<length(); ++number)
		{
			static if(isScalarType!(ReturnType) || isSomeString!(ReturnType))
				result = operations(number, opIndex(number));
			else
				mixin("result = operations(number,  parent."~accessor~"(temp, number));");
			if(result)
				break;
		}
		return result;
	}
	
	ReturnType[] opSlice(int start, int end)
	{
		ReturnType[] ret;
		ret.length = end - start;
		for(int i=start; i<end; i++)
			ret[i] = opIndex(i);
		return ret;
	}
	
	ReturnType[] opSlice()
	{
		return opSlice(0, length());
	}
}

mixin template Table(ParentType)
{
public: //Variables.
	ByteBuffer bb;
	int bb_pos;

private: //Methods.
	///Look up a field in the vtable, return an offset into the object, or 0 if the field is not present.
	int __offset(int vtableOffset)
	{
		int vtable = bb_pos - bb.getInt(bb_pos);
		return vtableOffset < bb.getShort(vtable)? cast(int)bb.getShort(vtable + vtableOffset) : 0;
	}
	
	///Retrieve the relative offset stored at "offset".
	int __indirect(int offset)
	{
		return offset + bb.getInt(offset);
	}
	
	///Create a D string from UTF-8 data stored inside the flatbuffer.
	string __string(int offset)
	{
		offset += bb.getInt(offset);
		auto len = bb.getInt(offset);
		auto startPos = offset + int.sizeof;
		return cast(string)bb.data[startPos..startPos+len];
	}
	
	///Get the length of a vector whose offset is stored at "offset" in this object.
	int __vector_len(int offset)
	{
		offset += bb_pos;
		offset += bb.getInt(offset);
		return bb.getInt(offset);
	}
	
	///Get the start of data of a vector whose offset is stored at "offset" in this object.
	int __dvector(int offset)
	{
		offset += bb_pos;
		return offset + bb.getInt(offset) + cast(int)int.sizeof; //Data starts after the length.
	}
	
	///Initialize any Table-derived type to point to the union at the given offset.
	T __union(T)(T t, int offset)
	{
		offset += bb_pos;
		t.bb_pos = offset + bb.getInt(offset);
		t.bb = bb;
		return t;
	}
	
	static bool __has_identifier(ByteBuffer bb, string ident)
	{
		import std.string;
		if(ident.length != fileIdentifierLength)
			throw new ArgumentException(format("FlatBuffers: file identifier must be length %s.", fileIdentifierLength), "ident");
		
		for(int i=0; i<fileIdentifierLength; i++)
		{
			if(ident[i] != cast(char)bb.get(bb.position() + cast(int)int.sizeof + i))
				return false;
		}
		
		return true;
	}
}

mixin template Struct(ParentType)
{
public: //Variables.
	ByteBuffer bb;
	int bb_pos;
}

final class FlatBufferBuilder
{
public: //Methods.
	this(int initialSize)
	{
		if(initialSize <= 0)
			throw new ArgumentOutOfRangeException("initialSize", initialSize, "Must be greater than zero");
		_space = initialSize;
		_bb = new ByteBuffer(new ubyte[](initialSize));
	}
	
	int offset() { return _bb.length - _space; }
	
	void pad(int size)
	{
		for(int i=0; i<size; i++)
			_bb.putByte(--_space, 0);
	}
	
	///Doubles the size of the ByteBuffer, and copies the old data towards
	///the end of the new buffer (since we build the buffer backwards).
	void growBuffer()
	{
		auto oldBuf = _bb.data;
		auto oldBufSize = oldBuf.length;
		if((oldBufSize & 0xC0000000) != 0)
			throw new Exception("FlatBuffers: cannot grow buffer beyond 2 gigabytes.");
		
		auto newBufSize = oldBufSize * 2;
		auto newBuf = new ubyte[](newBufSize);
		newBuf[newBufSize-oldBufSize..$] = oldBuf[];
		
		/*oldBuf.length = newBufSize;
		oldBuf[newBufSize-oldBufSize..$] = oldBuf[];*/
		//Buffer.BlockCopy(oldBuf, 0, newBuf, newBufSize - oldBufSize, oldBufSize);
		
		_bb = new ByteBuffer(newBuf);
		_bb._pos = 0;
	}
	
	///Prepare to write an element of `size` after `additional_bytes`
	///have been written, e.g. if you write a string, you need to align
	///such the int length field is aligned to SIZEOF_INT, and the string
	///data follows it directly.
	///If all you need to do is align, `additional_bytes` will be 0.
	void prep(int size, int additionalBytes)
	{
		//Track the biggest thing we've ever aligned to.
		if(size > _minAlign)
			_minAlign = size;
		
		//Find the amount of alignment needed such that `size` is properly
		//aligned after `additional_bytes`.
		auto alignSize = ((~(cast(int)_bb.length - _space + additionalBytes)) + 1) & (size - 1);
		
		//Reallocate the buffer if needed.
		while(_space < alignSize + size + additionalBytes)
		{
			auto oldBufSize = cast(int)_bb.length;
			growBuffer();
			_space += cast(int)_bb.length - oldBufSize;
		}
		
		pad(alignSize);
	}
	
	void putBool(bool x)
	{
		_bb.putByte(_space -= byte.sizeof, cast(byte)(x? 1 : 0));
	}
	
	void putByte(byte x)
	{
		_bb.putByte(_space -= byte.sizeof, x);
	}
	
	void putUbyte(byte x)
	{
		_bb.putUbyte(_space -= ubyte.sizeof, x);
	}
	
	void putShort(short x)
	{
		_bb.putShort(_space -= short.sizeof, x);
	}
	
	void putUshort(ushort x)
	{
		_bb.putUshort(_space -= ushort.sizeof, x);
	}
	
	void putInt(int x)
	{
		_bb.putInt(_space -= int.sizeof, x);
	}
	
	void putUint(uint x)
	{
		_bb.putUint(_space -= uint.sizeof, x);
	}
	
	void putLong(long x)
	{
		_bb.putLong(_space -= long.sizeof, x);
	}
	
	void putUlong(ulong x)
	{
		_bb.putUlong(_space -= ulong.sizeof, x);
	}
	
	void putFloat(float x)
	{
		_bb.putFloat(_space -= float.sizeof, x);
	}
	
	void putDouble(double x)
	{
		_bb.putDouble(_space -= double.sizeof, x);
	}
	
	///Adds a scalar to the buffer, properly aligned, and the buffer grown if needed.
	void addBool(bool x) { prep(byte.sizeof, 0); putBool(x); }
	void addByte(byte x) { prep(byte.sizeof, 0); putByte(x); }
	void addUbyte(ubyte x) { prep(ubyte.sizeof, 0); putUbyte(x); }
	void addShort(short x) { prep(short.sizeof, 0); putShort(x); }
	void addUshort(ushort x) { prep(ushort.sizeof, 0); putUshort(x); }
	void addInt(int x) { prep(int.sizeof, 0); putInt(x); }
	void addUint(uint x) { prep(uint.sizeof, 0); putUint(x); }
	void addLong(long x) { prep(long.sizeof, 0); putLong(x); }
	void addUlong(ulong x) { prep(ulong.sizeof, 0); putUlong(x); }
	void addFloat(float x) { prep(float.sizeof, 0); putFloat(x); }
	void addDouble(double x) { prep(double.sizeof, 0); putDouble(x); }
	
	///Adds on offset, relative to where it will be written.
	void addOffset(int off)
	{
		prep(int.sizeof, 0); //Ensure alignment is already done.
		if(off > offset())
			throw new ArgumentException("FlatBuffers: must be less than offset.", "off");
		
		off = offset() - off + cast(int)int.sizeof;
		putInt(off);
	}
	
	void startVector(int elemSize, int count, int alignment)
	{
		notNested();
		_vectorNumElems = count;
		prep(int.sizeof, elemSize * count);
		prep(alignment, elemSize * count); //Just in case alignment > int.
	}
	
	int endVector()
	{
		putInt(_vectorNumElems);
		return offset();
	}
	
	void nested(int obj)
	{
		//Structs are always stored inline, so need to be created right
		//where they are used. You'll get this assert if you created it
		//elsewhere.
		if(obj != offset())
			throw new Exception("FlatBuffers: struct must be serialized inline.");
	}
	
	void notNested()
	{
		//You should not be creating any other objects or strings/vectors
		//while an object is being constructed.
		if(_vtable)
			throw new Exception("FlatBuffers: object serialization must not be nested.");
	}

	void startObject(int numfields)
	{
		notNested();
		_vtable = new int[](numfields);
		_objectStart = offset();
	}
	
	///Set the current vtable at `voffset` to the current location in the buffer.
	void slot(int voffset)
	{
		_vtable[voffset] = offset();
	}
	
	///Add a scalar to a table at `o` into its vtable, with value `x` and default `d`.
	void addBool(int o, bool x, bool d) { if(x != d) { addBool(x); slot(o); } }
	void addByte(int o, byte x, byte d) { if(x != d) { addByte(x); slot(o); } }
	void addUbyte(int o, ubyte x, ubyte d) { if(x != d) { addUbyte(x); slot(o); } }
	void addShort(int o, short x, int d) { if(x != d) { addShort(x); slot(o); } }
	void addUshort(int o, ushort x, ushort d) { if(x != d) { addUshort(x); slot(o); } }
	void addInt(int o, int x, int d) { if(x != d) { addInt(x); slot(o); } }
	void addUint(int o, uint x, uint d) { if(x != d) { addUint(x); slot(o); } }
	void addLong(int o, long x, long d) { if(x != d) { addLong(x); slot(o); } }
	void addUlong(int o, ulong x, ulong d) { if(x != d) { addUlong(x); slot(o); } }
	void addFloat(int o, float x, double d) { if(x != d) { addFloat(x); slot(o); } }
	void addDouble(int o, double x, double d) { if(x != d) { addDouble(x); slot(o); } }
	void addOffset(int o, int x, int d) { if(x != d) { addOffset(x); slot(o); } }
	
	int createString(string s)
	{
		notNested();
		auto utf8 = cast(ubyte[])s;
		addUbyte(cast(ubyte)0);
		startVector(1, cast(int)utf8.length, 1);
		_space -= utf8.length;
		_bb.data[_space.._space+utf8.length] = utf8[];
		//Buffer.BlockCopy(utf8, 0, _bb.Data, _space -= utf8.Length, utf8.Length);
		return endVector();
	}
	
	///Structs are stored inline, so nothing additional is being added.
	///`d` is always 0.
	void addStruct(int voffset, int x, int d)
	{
		if(x != d)
		{
			nested(x);
			slot(voffset);
		}
	}
	
	int endObject()
	{
		if(!_vtable)
			throw new InvalidOperationException("Flatbuffers: calling endObject without a startObject");
		
		addInt(cast(int)0);
		auto vtableloc = offset();
		
		//Write out the current vtable.
		for(int i=cast(int)_vtable.length-1; i>=0; i--)
		{
			//Offset relative to the start of the table.
			short off = cast(short)(_vtable[i] != 0? vtableloc - _vtable[i] : 0);
			addShort(off);
		}
		
		const int standardFields = 2; //The fields below:
		addShort(cast(short)(vtableloc - _objectStart));
		addShort(cast(short)((_vtable.length + standardFields) * short.sizeof));
		
		///Search for an existing vtable that matches the current one.
		int existingVtable = 0;
		
		for(int i=0; i<_numVtables; i++)
		{
			int vt1 = _bb.length - _vtables[i];
			int vt2 = _space;
			short len = _bb.getShort(vt1);
			if(len == _bb.getShort(vt2))
			{
				for(int j=short.sizeof; j<len; j+=short.sizeof)
				{
					if(_bb.getShort(vt1 + j) != _bb.getShort(vt2 + j))
						goto endLoop;
				}
				existingVtable = _vtables[i];
				break;
			}
			
			endLoop: { }
		}
		
		if(existingVtable != 0)
		{
			//Found a match:
			//Remove the current vtable.
			_space = _bb.length - vtableloc;
			//Point table to existing vtable.
			_bb.putInt(_space, existingVtable - vtableloc);
		}
		else
		{
			//No match:
			//Add the location of the current vtable to the list of vtables.
			if(_numVtables == _vtables.length)
				_vtables.length *= 2;
			_vtables[_numVtables++] = offset();
			//Point table to current vtable.
			_bb.putInt(_bb.length - vtableloc, offset() - vtableloc);
		}
		
		destroy(_vtable);
		_vtable = null;
		return vtableloc;
	}
	
	///This checks a required field has been set in a given table that has
	///just been constructed.
	void required(int table, int field)
	{
		import std.string;
		int table_start = _bb.length - table;
		int vtable_start = table_start - _bb.getInt(table_start);
		bool ok = _bb.getShort(vtable_start + field) != 0;
		//If this fails, the caller will show what field needs to be set.
		if(!ok)
			throw new InvalidOperationException(format("FlatBuffers: field %s must be set.", field));
	}

	void finish(int rootTable)
	{
		prep(_minAlign, int.sizeof);
		addOffset(rootTable);
	}
	
	ByteBuffer dataBuffer() { return _bb; }
	
	///Utility function for copying a byte array that starts at 0.
	ubyte[] sizedByteArray()
	{
		/*auto newArray = new ubyte[_bb.Data.Length - _bb.position()];
		Buffer.BlockCopy(_bb.Data, _bb.position(), newArray, 0, _bb.Data.Length - _bb.position());
		return newArray;*/
		return _bb.data[_bb.position..$];
	}
	
	void finish(int rootTable, string fileIdentifier)
	{
		import std.string;
		prep(_minAlign, int.sizeof + fileIdentifierLength);
		if(fileIdentifier.length != fileIdentifierLength)
			throw new ArgumentException(format("FlatBuffers: file identifier must be length %s.", fileIdentifierLength), "fileIdentifier");
		for(int i=fileIdentifierLength-1; i>=0; i--)
			addByte(cast(ubyte)fileIdentifier[i]);
		addOffset(rootTable);
	}

private: //Variables.
	int _space;
	ByteBuffer _bb;
	int _minAlign = 1;
	
	///The vtable for the current table, null otherwise.
	int[] _vtable;
	///Starting offset of the current struct/table.
	int _objectStart;
	///List of offsets of all vtables.
	int[] _vtables = new int[](16);
	///Number of entries in `vtables` in use.
	int _numVtables = 0;
	///For the current vector being built.
	int _vectorNumElems = 0;
}

final class ByteBuffer
{
public: //Methods.
	int length()
	{
		return cast(int)_buffer.length;
	}
	
	ubyte[] data()
	{
		return _buffer;
	}
	
	this(ubyte[] buffer)
	{
		_buffer = buffer;
		_pos = 0;
	}
	
	int position()
	{
		return _pos;
	}
	
	void putByte(int offset, byte value)
	{
		assertOffsetAndLength(offset, byte.sizeof);
		_buffer[offset] = cast(byte)value;
		_pos = offset;
	}
	
	void putUbyte(int offset, ubyte value)
	{
		assertOffsetAndLength(offset, ubyte.sizeof);
		_buffer[offset] = value;
		_pos = offset;
	}
	
	void putShort(int offset, short value)
	{
		putUshort(offset, cast(ushort)value);
	}
	
	void putUshort(int offset, ushort value)
	{
		assertOffsetAndLength(offset, ushort.sizeof);
		version(LittleEndian)
			*cast(ushort*)(_buffer.ptr + offset) = value;
		else
			*cast(ushort*)(_buffer.ptr + offset) = swapEndian(value);
		_pos = offset;
	}
	
	void putInt(int offset, int value)
	{
		putUint(offset, cast(uint)value);
	}
	
	void putUint(int offset, uint value)
	{
		assertOffsetAndLength(offset, uint.sizeof);
		version(LittleEndian)
			*cast(uint*)(_buffer.ptr + offset) = value;
		else
			*cast(uint*)(_buffer.ptr + offset) = swapEndian(value);
		_pos = offset;
	}
	
	void putLong(int offset, long value)
	{
		putUlong(offset, cast(ulong)value);
	}
	
	void putUlong(int offset, ulong value)
	{
		assertOffsetAndLength(offset, ulong.sizeof);
		version(LittleEndian)
			*cast(ulong*)(_buffer.ptr + offset) = value;
		else
			*cast(ulong*)(_buffer.ptr + offset) = swapEndian(value);
		_pos = offset;
	}
	
	void putFloat(int offset, float value)
	{
		assertOffsetAndLength(offset, float.sizeof);
		version(LittleEndian)
			*cast(float*)(_buffer.ptr + offset) = value;
		else
			*cast(uint*)(_buffer.ptr + offset) = swapEndian(*cast(uint*)(&value));
		_pos = offset;
	}
	
	void putDouble(int offset, double value)
	{
		assertOffsetAndLength(offset, double.sizeof);
		version(LittleEndian)
			*cast(double*)(_buffer.ptr + offset) = value;
		else
			*cast(ulong*)(_buffer.ptr + offset) = swapEndian(*cast(ulong*)(_buffer + offset));
		_pos = offset;
	}
	
	byte getByte(int index)
	{
		assertOffsetAndLength(index, byte.sizeof);
		return cast(byte)_buffer[index];
	}
	
	ubyte getUbyte(int index)
	{
		assertOffsetAndLength(index, ubyte.sizeof);
		return _buffer[index];
	}
	
	ubyte get(int index)
	{
		assertOffsetAndLength(index, ubyte.sizeof);
		return _buffer[index];
	}
	
	short getShort(int offset)
	{
		return cast(short)getUshort(offset);
	}
	
	ushort getUshort(int offset)
	{
		assertOffsetAndLength(offset, ushort.sizeof);
		version(LittleEndian)
			return *cast(ushort*)(_buffer.ptr + offset);
		else
			return swapEndian(*cast(ushort*)(_buffer.ptr + offset));
	}
	
	int getInt(int offset)
	{
		return cast(int)getUint(offset);
	}
	
	uint getUint(int offset)
	{
		assertOffsetAndLength(offset, uint.sizeof);
		version(LittleEndian)
			return *cast(uint*)(_buffer.ptr + offset);
		else
			return swapEndian(*cast(uint*)(_buffer.ptr + offset));
	}
	
	long getLong(int offset)
	{
		return cast(long)getUlong(offset);
	}
	
	ulong getUlong(int offset)
	{
		assertOffsetAndLength(offset, ulong.sizeof);
		version(LittleEndian)
			return *cast(ulong*)(_buffer.ptr + offset);
		else
			return swapEndian(*cast(ulong*)(_buffer.ptr + offset));
	}
	
	float getFloat(int offset)
	{
		assertOffsetAndLength(offset, float.sizeof);
		version(LittleEndian)
			return *cast(float*)(_buffer.ptr + offset);
		else
		{
			uint uvalue = swapEndian(*cast(uint*)(_buffer.ptr + offset));
			return *cast(float*)(&uvalue);
		}
	}
	
	double getDouble(int offset)
	{
		assertOffsetAndLength(offset, double.sizeof);
		version(LittleEndian)
			return *cast(double*)(_buffer.ptr + offset);
		else
		{
			ulong uvalue = swapEndian(*cast(ulong*)(_buffer.ptr + offset));
			return *cast(double*)(&uvalue);
		}
	}

private: //Methods.
	void assertOffsetAndLength(int offset, int length)
	{
		import core.exception;
		import std.exception;
		if(offset < 0 || offset >= _buffer.length || offset+length > _buffer.length)
			throw new RangeError();
	}

private: //Variables.
	ubyte[] _buffer;
	int _pos;  //Must track start of the buffer.
}
