/*
 * Copyright 2014 Google Inc. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import flatbuffers;

import myGame.sample;

// Example how to use FlatBuffers to create and read binary buffers.

void main(string[] args)
{
	//Build up a serialized buffer algorithmically:
	auto builder = new FlatBufferBuilder(128);
	
	auto name = builder.createString("MyMonster");
	
	ubyte[] invData = [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 ];
	auto inventory = Monster.createInventoryVector(builder, invData);
	
	//Create monster:
	Monster.startMonster(builder);
	Monster.addPos(builder, Vec3.createVec3(builder, 1, 2, 3));
	Monster.addMana(builder, 150);
	Monster.addHp(builder, 80);
	Monster.addName(builder, name);
	Monster.addInventory(builder, inventory);
	Monster.addColor(builder, Color.blue);
	auto mloc = Monster.endMonster(builder);
	
	builder.finish(mloc);
	//We now have a FlatBuffer we can store or send somewhere.
	
	//** file/network code goes here :) **
	//access builder.sizedByteArray() for builder.sizedByteArray().length bytes
	
	//Instead, we're going to access it straight away.
	//Get access to the root:
	auto monster = Monster.getRootAsMonster(new ByteBuffer(builder.sizedByteArray()));
	
	assert(monster.hp == 80);
	assert(monster.mana == 150); //default
	assert(monster.name == "MyMonster");
	
	auto pos = monster.pos();
	assert(!pos.isNull());
	assert(pos.z == 3);
	
	auto inv = monster.inventory();
	assert(inv.length);
	assert(inv[9] == 9);
}
