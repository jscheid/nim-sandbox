import React from 'react';
import CodeMirrorEditor from 'react-code-mirror';
import CodeMirrorNim from './nimrod';
import ansiHTML from 'ansi-html';

require('./CodeMirrorStyle.css');

const codeMirrorStyles = {
  position: 'absolute',
  width: '100%',
  height: '100%',
};

export default class StderrDisplay extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      text: '',
    };
  }

  static contextTypes = {
    workerEmitter: React.PropTypes.any,
  };

  componentDidMount() {
    this.context.workerEmitter.on('stderr', data => {
      this.setState({ text: this.state.text + ansiHTML(data) + '\n' });
    });
  }

  render() {
    return (
      <div
        style={{ whiteSpace: 'pre', fontFamily: 'monospace' }}
        dangerouslySetInnerHTML={{ __html: this.state.text }}
      />
    );
  }
}
