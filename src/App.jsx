import React from 'react';
import SplitPane from 'react-split-pane';
import App from 'react-toolbox/lib/app/index';
import NimEditor from './NimEditor';
import JsDisplay from './JsDisplay';
import ToolBar from './ToolBar';
import StderrDisplay from './StderrDisplay';

require('./ReactSplitPane.css');

export default class Application extends React.Component {
  static childContextTypes = {
    workerEmitter: React.PropTypes.any,
    worker: React.PropTypes.any,
  };

  getChildContext() {
    return {
      workerEmitter: this.props.workerEmitter,
      worker: this.props.worker,
    };
  }

  render() {
    return (
      <div style={{ display: 'flex', width: '100%', height: '100%', position: 'absolute', flexDirection: 'column' }}>
        <ToolBar/>
        <div style={{ position: 'relative', width: '100%', flexGrow: 1 }}>
          <SplitPane split="vertical" minSize="50">
            <NimEditor/>
            <SplitPane split="horizontal">
              <JsDisplay/>
              <StderrDisplay/>
            </SplitPane>
          </SplitPane>
        </div>
      </div>
    );
  }
}
