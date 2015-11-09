import React from 'react';
import { render } from 'react-dom';
import Application from './App';
import EventEmitter from 'events';

const workerEmitter = new EventEmitter({});
const worker = new Worker('/static/worker.entry.js');
worker.onmessage = event => {
  workerEmitter.emit(event.data.type, event.data.data);
};

render(<Application worker={worker} workerEmitter={workerEmitter}/>, document.getElementById('root'));
