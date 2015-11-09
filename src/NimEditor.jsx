import React from 'react';
import CodeMirrorEditor from 'react-code-mirror';
import CodeMirrorNim from './nimrod';

require('./CodeMirrorStyle.css');

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
      mode: 'nimrod',
    };
    this.codeMirrorOptions = {
      lineNumbers: true
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
        value={this.state.code}
        onChange={::this.updateCode}
        options={this.codeMirrorOptions}
        style={codeMirrorStyles}
      />
    );
  }

  updateCode(event) {
    this.setState({
      code: event.target.value,
    });
  }
}
