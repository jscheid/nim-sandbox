import React from 'react';
import CodeMirrorEditor from 'react-code-mirror';
import CodeMirrorNim from './nimrod';

require('./CodeMirrorStyle.css');
require('codemirror/mode/javascript/javascript');

const codeMirrorStyles = {
  position: 'absolute',
  width: '100%',
  height: '100%',
};

export default class JsDisplay extends React.Component {

  static contextTypes = {
    workerEmitter: React.PropTypes.any,
  };

  constructor(props) {
    super(props);
    this.state = {
      code: '// Generated JavaScript will appear here',
    };
    this.codeMirrorOptions = {
      lineNumbers: true
    };
  }

  componentDidMount() {
    this.context.workerEmitter.on('compilation', data => {
      this.setState({ code: data });
    });
  }

  render() {
    return (
      <CodeMirrorEditor
        value={this.state.code}
        mode='javascript'
        theme='material'
        lineNumbers={true}
        style={codeMirrorStyles}
        readOnly
      />
    );
  }
}
