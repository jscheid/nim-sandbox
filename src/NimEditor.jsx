import React from 'react';
import CodeMirrorEditor from 'react-code-mirror';
import CodeMirrorNim from './nimrod';

require('codemirror/lib/codemirror.css');
require('./CodemirrorOverride.css');

const codeMirrorStyles = {
  position: 'absolute',
  width: '100%',
  height: '100%',
};

export default class NimEditor extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      code: '// Code',
      mode: 'nimrod',
    };
    this.codeMirrorOptions = {
      lineNumbers: true
    };
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
