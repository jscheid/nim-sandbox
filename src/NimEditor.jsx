import React from 'react';
import CodeMirrorEditor from 'react-code-mirror';
import CodeMirrorNim from './nimrod';

require('./CodeMirrorStyle.css');
require('codemirror/theme/material.css');

const codeMirrorStyles = {
  position: 'absolute',
  width: '100%',
  height: '100%',
};

export default class NimEditor extends React.Component {

  static contextTypes = {
    workerEmitter: React.PropTypes.any,
    worker: React.PropTypes.any,
  };

  constructor(props) {
    super(props);
    this.state = {
      code: '# Example Code\necho "Hello, World!"',
    };
  }

  componentDidMount() {
    this.context.workerEmitter.on('startCompilation', () => {
      this.context.worker.postMessage({
        source: this.state.code,
        flags: [ '-d:release' ],
      });
    });
  }

  render() {
    return (
      <CodeMirrorEditor
        {...this.codeMirrorOptions}
        value={this.state.code}
        onChange={::this.updateCode}
        style={codeMirrorStyles}
        mode="nimrod"
        theme="material"
        lineNumbers={true}
      />
    );
  }

  updateCode(event) {
    this.setState({
      code: event.target.value,
    });
  }
}
