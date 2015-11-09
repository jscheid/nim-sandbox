import React from 'react';
import CodeMirrorEditor from 'react-code-mirror';
import CodeMirrorNim from './nimrod';

require('./CodeMirrorStyle.css');

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
      code: '# Generated JavaScript will appear here',
      mode: 'javascript',
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
        options={this.codeMirrorOptions}
        style={codeMirrorStyles}
        readOnly
      />
    );
  }
}
